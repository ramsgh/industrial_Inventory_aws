# AWS EC2 deployment: learning notes and troubleshooting

This document summarizes the AWS deployment choices, the issues encountered, and how to operate the EC2 + Docker Compose setup later. It is a companion to [`README-AWS-EC2.md`](README-AWS-EC2.md), which has the full deployment instructions.

For architecture diagrams showing the AWS resources, security boundaries, and request/data flows, see [`AWS-ARCHITECTURE-DIAGRAM.md`](AWS-ARCHITECTURE-DIAGRAM.md).

> **Important:** Never put AWS access keys, secret keys, passwords, MFA codes, authorization tokens, private IP allowlists, or unredacted account details in this document, source control, or chat.

## The application in simple terms

The app has five containers:

| Container | What it does | Port |
| --- | --- | ---: |
| `inventory-frontend` | React inventory page | 3000 |
| `api-gateway` | Receives browser API requests and routes them to the product service | 8080 |
| `product-service` | Reads and writes product records | 8081 |
| `service-registry` | Lets Spring services discover one another | 8761 |
| `mongodb` | Stores product records | 27017 |

The browser loads the React page from port `3000`. The page sends product API requests to the gateway on port `8080`. The gateway finds `product-service` through Eureka, and the product service reads or writes records in MongoDB.

The Docker Compose setup runs all five containers on one machine. For AWS learning, the selected Terraform configuration creates one EC2 instance and runs Docker Compose on that instance. It also creates a separate encrypted EBS volume mounted for MongoDB's data directory.

There is another, more complex Terraform setup at `terraform/aws` for ECS Fargate, S3, and CloudFront. This guide is about `terraform/aws-ec2-compose`; do not run Terraform commands in the other directory for this deployment.

## What Terraform creates

The EC2 configuration creates:

- One VPC, public subnet, internet gateway, and route to the internet.
- One EC2 instance running Amazon Linux 2023.
- A security group that allows UI/API traffic only from `allowed_client_cidr`.
- An IAM role and instance profile so the instance can be accessed through Systems Manager Session Manager.
- An encrypted root EBS disk for the operating system.
- A separate encrypted gp3 EBS disk for MongoDB data.

It does not create an Elastic IP, load balancer, ECS cluster, EFS, S3 bucket, or CloudFront distribution. The instance gets an automatically assigned public IPv4 address. That address can change when the instance is replaced or stopped and started.

On first boot, the Terraform user-data script installs Docker and the Compose plugin, identifies and mounts the MongoDB EBS disk, clones the configured Git branch, writes the public-address settings, and runs `docker compose up --build -d`. Building Java and frontend images takes several minutes, so the page may not respond immediately after `terraform apply` completes.

## AWS credentials and Terraform state

The AWS CLI profile is used to authenticate Terraform. Verify which AWS identity is active before planning:

```bash
export AWS_PROFILE=ramshy
aws sts get-caller-identity
```

The returned ARN should identify the IAM user/profile you expect. If it identifies another user or account, stop and correct the profile before running Terraform.

Terraform state records which AWS resources it created. Keep the following in `terraform/aws-ec2-compose` between deployment, update, and destroy operations:

- `terraform.tfstate`
- `.terraform/`
- `terraform.tfvars`

Do not delete, commit, or share `terraform.tfstate` or `terraform.tfvars`. The repository `.gitignore` excludes them. If state is lost, Terraform may no longer know which resources belong to this deployment.

## Issues encountered and resolutions

| Symptom | Cause | Resolution / lesson |
| --- | --- | --- |
| AWS CLI asked for access key ID, secret, region, and output format | A CLI profile had not yet been configured. | Create an IAM-user key in the AWS Console, configure it with `aws configure --profile ramshy`, use `us-east-1` for the selected region, and choose `json` or press Enter for output format. Never create root access keys. |
| IAM pages or key creation showed AccessDenied | The IAM user did not have the relevant IAM permissions. | An AWS administrator must grant the needed permissions. An IAM user cannot give itself permissions unless already authorized. Avoid granting permanent broad admin permissions for convenience. |
| Terraform could not read the Amazon Linux AMI parameter | Missing `ssm:GetParameter` permission. | The administrator granted read access to the public Amazon Linux AMI parameter in the selected region. |
| Terraform could not find an Availability Zone | Missing `ec2:DescribeAvailabilityZones`. | This read-only EC2 permission was added for the IAM user. |
| Terraform could not create a VPC | Missing `ec2:CreateVpc` (and potentially related network permissions). | The IAM policy needed the EC2/VPC actions used by this Terraform configuration. |
| EBS volume creation reported `ec2:CreateTags` | Terraform applies provider default tags while creating the volume. | The administrator added a narrowly scoped `ec2:CreateTags` permission for volume creation. |
| Elastic IP creation reported `ec2:AllocateAddress` | The initial EC2 design allocated an Elastic IP, requiring additional IAM permission and incurring possible IPv4 charges. | The Elastic IP resource was removed. The EC2 instance's automatically assigned public IP is used instead. |
| IAM role/profile creation was denied | Terraform creates an instance role/profile for Systems Manager access and tags those resources. | IAM administrator permissions were required for the role and instance-profile operations. IAM inline policies attached directly to a user have a size limit; a customer-managed policy can be used when a policy is too large. |
| Homebrew refused to install Terraform from HashiCorp's tap | Homebrew required explicit trust for that formula. | Verify the tap is `hashicorp/tap`, then trust only the Terraform formula as documented in `README-AWS-EC2.md`. |
| Browser could not connect to the first instance | EC2 user data tried to install `curl`, conflicting with Amazon Linux's installed `curl-minimal`; bootstrap exited before starting Compose. | Removed `curl` from the package install list. The bootstrap uses the existing `curl-minimal`. Terraform replaces the instance when user data changes, while retaining the separately managed MongoDB disk. |
| Browser initially could not connect to the replacement instance | The app's images were still building during first boot. | Wait for bootstrap to finish; inspect the bootstrap log and container status before retrying the page. Once startup completed, the frontend responded and the API returned HTTP 200. |
| Product form displayed an Unauthorized alert locally | The API gateway rejected the browser's CORS preflight `OPTIONS` request. | Gateway security was changed to permit `OPTIONS` requests; the preflight and an authenticated product POST then succeeded. |
| MongoDB container exited with `mongo:latest` | The moving `latest` image was incompatible with the Docker VM's Linux kernel. | Local Compose pins MongoDB to `mongo:7.0` and includes a health check. |

### IAM permission failures

Terraform needs more than permission to launch an instance: it also reads AMI/availability data, creates network resources, configures security groups, attaches storage, and creates the SSM instance role/profile. AWS may report missing permissions one at a time as it progresses.

#### Permission errors seen in this deployment

These were the specific IAM permission issues encountered while applying this Terraform stack:

| AWS error/action | Why Terraform needed it |
| --- | --- |
| IAM console pages or access-key creation denied | The IAM user initially lacked permission to view IAM resources or manage its own access key. |
| `ssm:GetParameter` | Read the public Amazon Linux 2023 AMI ID from the AWS Systems Manager public parameter. |
| `ec2:DescribeAvailabilityZones` | Select an Availability Zone for the subnet and EBS volume. |
| `ec2:CreateVpc` (and subsequent VPC-related actions) | Create the VPC, subnet, internet gateway, route table, and security group. |
| `ec2:AllocateAddress` | Required by the original design's Elastic IP. The Elastic IP was removed, so this permission is no longer needed by the current configuration. |
| `ec2:CreateVolume` / `ec2:CreateTags` | Create and tag the separate EBS volume used for MongoDB data. The actual failure reported `ec2:CreateTags`. |
| `iam:CreateRole` and role policy actions | Create the EC2 instance role and attach the Systems Manager managed policy. |
| `iam:CreateInstanceProfile` and `iam:TagInstanceProfile` | Create and tag the instance profile that connects the role to EC2. |

The errors appeared incrementally because Terraform only reaches later AWS API operations after earlier resources have been created. A permission fix for one action does not imply that all required permissions are present.

#### Safe process for resolving access denied

1. Run `aws sts get-caller-identity --profile ramshy` and confirm the account and IAM user are the ones where permissions were changed. Terraform uses whichever credential source is active in that terminal; an explicit profile is safest:

   ```bash
   export AWS_PROFILE=ramshy
   aws sts get-caller-identity
   ```

2. Copy the exact denied action and resource from the AWS error, for example `ec2:CreateVpc`. Do not share credentials or the encoded authorization failure text.
3. Ask the account root user or IAM administrator to grant only the required actions and resource scope where practical. Check the user's attached policies and permissions boundary, and check whether an AWS Organizations SCP contains a deny. An explicit deny or boundary/SCP restriction can override an allow policy.
4. Save and attach the policy to the correct user/role, then rerun `terraform plan` with the same profile and state.

IAM policy editor input must be a complete JSON policy document with `Version` and `Statement`, not just a single `Effect`/`Action` snippet. Inline policies attached to a user have a small size limit (2,048 characters in this case); when a complete policy exceeds that limit, create a customer-managed policy and attach it to the user instead.

The user also encountered an error when pasting only a policy statement (`The Policy element Effect is not valid`). The fix is to paste a complete policy document in the JSON editor. Avoid adding broad `AdministratorAccess` or `AmazonEC2FullAccess` permanently simply to silence errors; if an administrator temporarily uses broad access for a learning account, remove it after cleanup and review the security impact.

When this happens:

1. Read the full error and note the exact denied action and resource.
2. Give that information to the account's AWS administrator.
3. Ask the administrator to review identity policies, permissions boundaries, and Organizations service control policies.
4. After the permission is fixed, run `terraform plan` again using the same profile and state.

Do not copy encoded authorization messages into notes; they are not needed for normal troubleshooting. Do not use an all-powerful policy permanently just to silence errors.

## Running a short learning session

From a terminal, start in the EC2 Terraform directory:

```bash
cd terraform/aws-ec2-compose
export AWS_PROFILE=ramshy
aws sts get-caller-identity
terraform plan
terraform apply
```

Review the plan before confirming. After `apply` completes, get the address:

```bash
terraform output
```

Open the current `frontend_url` output. Do not reuse an old URL after the EC2 instance has been replaced; its public IP may have changed.

Check the API response:

```bash
curl -i "$(terraform output -raw api_url)"
```

A `200 OK` response with a JSON array (possibly empty) indicates the gateway/product/database path is responding.

### If the browser page does not open

1. Confirm you used the latest `terraform output -raw frontend_url`.
2. Confirm `allowed_client_cidr` in `terraform.tfvars` is your current public IP with `/32`. Find the current IP with:

   ```bash
   curl -4 https://checkip.amazonaws.com
   ```

3. If your IP changed, update `allowed_client_cidr`, then run `terraform apply`.
4. Wait several minutes after first boot for Maven/npm image builds.
5. Inspect the instance startup log through Session Manager:

   ```bash
   INSTANCE_ID=$(terraform output -raw instance_id)
   aws ssm start-session --target "$INSTANCE_ID"
   ```

   On the instance:

   ```bash
   sudo tail -n 200 /var/log/inventory-bootstrap.log
   cd /opt/industrial-inventory
   sudo docker compose ps
   sudo docker compose logs --tail=100
   ```

6. Re-check the API with the `curl` command above. Do not open MongoDB, Eureka, or the product-service ports publicly.

If `aws ssm start-session` fails, the local Session Manager plugin and the IAM user's SSM permissions may be missing. The EC2 instance role also needs the Systems Manager managed policy.

## Stop for now, continue later

For a short pause where you want to keep the instance and database, you can stop the instance:

```bash
aws ec2 stop-instances --instance-ids "$(terraform output -raw instance_id)"
```

EBS volumes continue to incur storage charges while the instance is stopped. When restarted, the automatically assigned public IP may change; update the app URL and `APP_FRONTEND_ORIGIN`/frontend API configuration if needed. For a beginner, destroying and recreating the deployment is usually clearer, but it deletes the database disk.

To run Compose manually on the EC2 host, connect via Session Manager and use:

```bash
cd /opt/industrial-inventory
sudo docker compose up -d
sudo docker compose ps
sudo docker compose logs -f
```

`Ctrl+C` while running `docker compose logs -f` stops only the log display. `Ctrl+C` during foreground `docker compose up` stops the containers. The bootstrap uses `docker compose up --build -d`, so its containers run detached.

## MongoDB data: retain or delete

MongoDB data is stored on the separate encrypted EBS volume mounted at `/mnt/mongo-data`. It survives container restarts and EC2 replacement as long as Terraform retains the EBS volume.

- `docker compose down` stops/removes containers; it does not erase the EBS data.
- Stopping the EC2 instance retains the EBS data but does not stop EBS storage charges.
- `terraform destroy` deletes the Terraform-managed EBS volume and its MongoDB data. Export or snapshot anything important before destroying.
- A fresh `terraform apply` after a full destroy creates a new, empty MongoDB volume.

## Cost and cleanup

Cost depends on region, instance type, storage size, runtime, traffic, account credits, and AWS pricing at the time. The configured example uses a `t3.medium` and two 20 GiB gp3 volumes. An earlier rough estimate was around **$37/month** for continuous operation in `us-east-1`, before taxes, unusual traffic, or CPU-credit charges; use the AWS Pricing Calculator and Billing console for current account-specific numbers.

Stopping EC2 stops compute billing but does not stop EBS storage billing. Destroy the stack after a learning session to stop ongoing charges:

```bash
terraform plan
terraform destroy
```

Review the destroy plan carefully. It deletes the EBS MongoDB volume and all records on it. Do not manually delete Terraform state before destroy; Terraform needs the state to identify the resources.

The educational application uses hard-coded demo credentials (`admin` / `admin123`) and HTTP. Keep the security-group allowlist limited to your own current IP, do not store sensitive inventory, and do not treat this setup as production-secure.
