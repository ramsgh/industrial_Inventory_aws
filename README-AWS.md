# AWS Deployment (ECS Fargate, S3, and CloudFront)

This guide deploys the Industrial Inventory app to AWS. The Java services run as ECS Fargate tasks, MongoDB runs as a single ECS task with encrypted EFS-backed data, and the React production build is served privately from S3 through CloudFront. CloudFront also forwards `/api/*` requests to the API gateway's Application Load Balancer.

This is a learning/demo deployment, not a production reference architecture. It uses one MongoDB task, HTTP between CloudFront and the ALB, public subnets for Fargate tasks, and the project's hard-coded demo admin credentials. Review the security and cost notes below before using it beyond experimentation.

## What gets created

- VPC, public subnets in two availability zones, internet gateway, and security groups
- ECS cluster and Fargate services for Eureka, product service, API gateway, and MongoDB
- AWS Cloud Map private DNS for internal service discovery
- ECR repositories for the three Java images
- Encrypted EFS storage for MongoDB data
- Application Load Balancer for the API gateway
- Private S3 bucket and CloudFront distribution for the React site and `/api/*` requests
- CloudWatch log groups for container logs

The initial Terraform apply creates the AWS infrastructure with ECS service desired counts set to zero. This allows the ECR repositories and infrastructure to be created before the Java container images are pushed.

## Prerequisites

- An AWS account and credentials configured for the AWS CLI (`aws configure`, an AWS profile, or an assigned IAM role)
- Terraform 1.5 or newer
- AWS CLI v2
- Docker with Buildx and support for building `linux/amd64` images
- Node.js and npm
- IAM permissions to create/manage VPC, ECS, ECR, EFS, CloudFront, S3, IAM roles, Cloud Map, CloudWatch Logs, and load balancer resources

Choose an AWS region supported by Fargate, EFS, and CloudFront. The Terraform default is `us-east-1`. Creating these resources can incur charges, including for Fargate, EFS, the load balancer, CloudFront, and data transfer.

## 1. Create the infrastructure

From the repository root:

```bash
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` to select the AWS region and project name. The defaults start services with `desired_count = 0`; keep that setting for the first apply.

```bash
aws sts get-caller-identity
terraform init
terraform fmt -check
terraform validate
terraform plan
terraform apply
```

Review the plan before approving it. Save the outputs for the following steps:

```bash
terraform output
```

Terraform state contains infrastructure metadata. Keep `terraform.tfstate` and `terraform.tfvars` private; they are excluded by the repository `.gitignore`.

## 2. Build and push the Java images to ECR

Run these commands from the repository root. Set the region to the same value as `terraform.tfvars`:

```bash
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

for service in service-registry product-service api-gateway; do
  docker buildx build --platform linux/amd64 --push \
    --tag "${ECR_REGISTRY}/industrial-inventory/${service}:latest" \
    "./${service}"
done
```

If you chose a different Terraform `project_name`, replace `industrial-inventory` in the image paths with that project name. The Terraform ECR repository URLs are shown by running `terraform output ecr_repository_urls` from `terraform/aws`.

Each Java Dockerfile runs `mvn clean package` in its image build stage. The images published above are the same artifacts ECS will run.

## 3. Start the Fargate services

After the images have been pushed, edit `terraform.tfvars` and change `desired_count` from `0` to `1`. Then apply the updated configuration:

```bash
terraform apply
```

Wait until the MongoDB, Eureka, product-service, and API-gateway tasks are running. Check them with:

```bash
CLUSTER=$(terraform output -raw ecs_cluster_name)
aws ecs list-services --cluster "$CLUSTER"
aws ecs list-tasks --cluster "$CLUSTER"
```

The cluster name is available from `terraform output ecs_cluster_name`. Container logs are in CloudWatch under `/ecs/<project-name>/<service-name>`. Keep `desired_count = 1` in `terraform.tfvars` for future Terraform applies.

## 4. Build and upload the React frontend

From the repository root, build the frontend to use the same-origin `/api/products` URL. The CloudFront distribution serves the frontend and forwards that API path to the ALB:

```bash
cd inventory-frontend
npm install
REACT_APP_API_URL=/api/products npm run build
cd ..
```

Upload the static build and invalidate the CloudFront cache:

```bash
cd terraform/aws
FRONTEND_BUCKET=$(terraform output -raw frontend_bucket_name)
DISTRIBUTION_ID=$(terraform output -raw cloudfront_distribution_id)

aws s3 sync ../../inventory-frontend/build/ "s3://${FRONTEND_BUCKET}/" --delete
aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/*"
```

Open the frontend URL:

```bash
terraform output -raw frontend_url
```

The first CloudFront deployment can take several minutes to become available.

## 5. Verify the deployment

Get the site URL:

```bash
cd terraform/aws
APP_URL=$(terraform output -raw frontend_url)
curl -i "${APP_URL}/api/products"
```

A `200 OK` response with a JSON array (possibly empty) means the API gateway, product service, and MongoDB are reachable through CloudFront. Add a product through the UI, then refresh the product list.

The current demo UI sends HTTP Basic credentials (`admin` / `admin123`) automatically. Product creation should not be exposed publicly with these credentials; replace the authentication implementation before any real deployment.

## Local Docker Compose versus AWS

`docker compose up --build` is for running the application on your local Docker host. It builds images locally and runs all services as local containers; it does not deploy or control AWS resources.

For AWS, Terraform provisions the infrastructure, Docker images are built and pushed to ECR, ECS runs the containers, and the React build is uploaded to S3. ECR repositories use immutable tags. To deploy newer backend code, build and push the images with a new tag, update `image_tag` in `terraform.tfvars`, and run `terraform apply` to register new task definitions and replace the running tasks. To publish frontend changes, create a new React build, sync it to S3, and invalidate CloudFront.

For example, from the repository root, publish a new backend release with a unique tag:

```bash
export RELEASE_TAG=v2

for service in service-registry product-service api-gateway; do
  docker buildx build --platform linux/amd64 --push \
    --tag "${ECR_REGISTRY}/industrial-inventory/${service}:${RELEASE_TAG}" \
    "./${service}"
done
```

Set `image_tag = "v2"` in `terraform/aws/terraform.tfvars`, then run `terraform apply` from `terraform/aws`.

## Database access and persistence

MongoDB is not exposed to the public internet. Its data directory is stored on encrypted EFS and MongoDB is registered only in the VPC's private Cloud Map namespace. ECS Exec is enabled for the services. With the AWS CLI Session Manager plugin installed, inspect MongoDB with:

```bash
CLUSTER=$(terraform output -raw ecs_cluster_name)
MONGODB_TASK=$(aws ecs list-tasks \
  --cluster "$CLUSTER" \
  --service-name mongodb \
  --desired-status RUNNING \
  --query 'taskArns[0]' \
  --output text)

aws ecs execute-command \
  --cluster "$CLUSTER" \
  --task "$MONGODB_TASK" \
  --container mongodb \
  --interactive \
  --command "mongosh inventory_db"
```

At the MongoDB prompt, run `db.products.find().pretty()` to view products. Do not open MongoDB's port to the internet.

The demo runs one MongoDB task without database authentication. EFS provides persistence across task replacement, but it does not turn this single task into a highly available MongoDB cluster.

## Tear down

From `terraform/aws`, destroy the AWS resources when finished:

```bash
terraform destroy
```

The S3 bucket and EFS filesystem contain data and are intentionally not force-deleted. Empty the frontend bucket before destroying Terraform resources if it contains uploaded files:

```bash
aws s3 rm "s3://$(terraform output -raw frontend_bucket_name)" --recursive
terraform destroy
```

Destroying the EFS filesystem permanently deletes the MongoDB data. Confirm that this is acceptable before approving Terraform's destroy plan.
The ECR repositories are configured for Terraform to delete their pushed images when destroyed.
