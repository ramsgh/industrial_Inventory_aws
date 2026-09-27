# AWS EC2 + Docker Compose deployment

This is a lower-complexity alternative to the ECS/Fargate Terraform stack. It creates one Amazon Linux 2023 EC2 instance, installs Docker Compose, clones the application repository, and runs `docker compose up --build -d`. MongoDB stores its files on a separate encrypted EBS volume that survives instance stops and replacement/termination.

The stack includes one EC2 instance, one Elastic IP, an internet gateway, a security group, an SSM instance role, and two EBS volumes. It does not create an ALB, ECS, EFS, CloudFront, or S3. This is for educational use, not production.

## Requirements

- Terraform 1.5 or newer
- AWS CLI v2 with credentials and permissions to manage EC2, VPC, IAM, and SSM
- A Git repository that the EC2 instance can clone over HTTPS (the configured default repository must be publicly readable)
- A Docker Compose v2-compatible client on your local computer is not required; Compose runs on EC2

The recommended `t3.medium` has 4 GiB of RAM. It is more likely to run MongoDB, the three Spring Boot services, and the React development server reliably than a `t3.micro`/`t3.small`. You can set `instance_type` to a smaller size for experimentation, but the app may run out of memory. Free-tier/credit eligibility depends on your AWS account and current AWS terms; EC2, EBS, and public IPv4 may still cost money.

## Before applying

Push the application code and Compose configuration you intend to run to a branch the instance can read. The EC2 bootstrap clones the repository URL and branch once at first boot. If the repository is private, this default bootstrap will not be able to clone it. Do not put a GitHub personal access token in Terraform user data; user data can be read through AWS APIs. Use a secure private-repository deployment method instead.

The security group only permits the UI and API from `allowed_client_cidr`. Determine your public IPv4 address and use its `/32` CIDR:

```bash
curl -4 https://checkip.amazonaws.com
```

If your public IP changes, update the CIDR in `terraform.tfvars` and re-apply.

## Deploy

From the repository root:

```bash
cd terraform/aws-ec2-compose
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`; replace the example `allowed_client_cidr` with your actual address, and confirm the Git repository/branch. Then:

```bash
aws sts get-caller-identity
terraform init
terraform fmt -check
terraform validate
terraform plan
terraform apply
```

Review the plan and type `yes` when prompted. On first boot, cloud-init installs Docker and the Compose plugin, formats and mounts the dedicated MongoDB EBS volume if it is blank, clones the repository, writes host-specific frontend/API settings, then builds and starts the application.

Get the app URL and instance ID:

```bash
terraform output
```

Open the `frontend_url` from your browser. The bootstrap may need several minutes to finish compiling the Java services and frontend assets.

## Check startup and service status

Connect without opening SSH:

```bash
INSTANCE_ID=$(terraform output -raw instance_id)
aws ssm start-session --target "$INSTANCE_ID"
```

Inside the instance, inspect bootstrap logs and Compose status:

```bash
sudo tail -n 200 /var/log/inventory-bootstrap.log
cd /opt/industrial-inventory
sudo docker compose ps
sudo docker compose logs --tail=100
```

The frontend is on port `3000`; API requests go to port `8080`. The MongoDB port is bound to EC2 localhost and is not allowed through the security group. Do not expose MongoDB, Eureka, or the product-service ports publicly.

## MongoDB persistence

MongoDB data is stored at `/mnt/mongo-data` on the separately attached encrypted gp3 EBS volume. Container recreation, Compose down/up, and EC2 stop/start do not remove this volume. The data volume uses `delete_on_termination = false`; however, `terraform destroy` deletes the Terraform-managed EBS volume and its data. Snapshot or otherwise back up the volume before destroying the stack if the data matters.

## Update the application

The bootstrap clones the repository only when the EC2 instance is first created. To update code after pushing it to the repository:

```bash
INSTANCE_ID=$(terraform output -raw instance_id)
aws ssm start-session --target "$INSTANCE_ID"
```

On the instance:

```bash
cd /opt/industrial-inventory
sudo git pull --ff-only
sudo docker compose up --build -d
```

## Stop and clean up

Stop containers but keep the EC2 instance and MongoDB data:

```bash
INSTANCE_ID=$(terraform output -raw instance_id)
aws ssm start-session --target "$INSTANCE_ID"
```

Then on the instance:

```bash
cd /opt/industrial-inventory
sudo docker compose down
```

To stop EC2 compute billing while retaining the EBS database volume, stop the instance from the AWS Console or run:

```bash
aws ec2 stop-instances --instance-ids "$(terraform output -raw instance_id)"
```

EBS storage and the Elastic IP may still incur charges while stopped. Start the instance from the console or with `aws ec2 start-instances`; Docker is enabled at boot, but the Compose app is started by the one-time bootstrap, so after an instance reboot bring it up with `sudo docker compose up -d` in `/opt/industrial-inventory`. The Elastic IP keeps the frontend and API URLs stable.

To delete everything:

```bash
terraform destroy
```

Destroying Terraform resources deletes the MongoDB EBS volume and all database contents. Back up or snapshot it first if needed.

## Security note

The demo application contains hard-coded `admin` / `admin123` credentials. The React frontend sends these credentials for product writes. Restrict `allowed_client_cidr` to your own IP, do not use real or sensitive inventory data, and do not expose this demo unchanged as a public production service. Traffic is HTTP; use HTTPS and proper secret-based authentication before production use.
