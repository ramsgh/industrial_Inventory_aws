# Industrial Inventory

A containerized inventory management application built with a React frontend and Spring Boot microservices. Product records are stored in MongoDB, and the frontend accesses the product API through an API gateway.

## Architecture

| Component | Technology | Port | Purpose |
| --- | --- | ---: | --- |
| `inventory-frontend` | React 18 | 3000 | Inventory dashboard for listing and adding products |
| `api-gateway` | Spring Cloud Gateway | 8080 | Routes `/api/products/**` requests to the product service and protects write requests |
| `product-service` | Spring Boot, Spring Data MongoDB | 8081 | Product API and persistence |
| `service-registry` | Netflix Eureka | 8761 | Service discovery |
| `mongodb` | MongoDB | 27017 | Stores the `inventory_db` database |

Docker Compose creates a shared network for the services and a named `mongo-data` volume so database records persist when containers are stopped or recreated.
MongoDB is pinned to the 7.0 release line instead of `latest` to avoid incompatible image updates. Its host port is bound to localhost only.

## Prerequisites

- Docker Desktop (or Docker Engine) with the Docker Compose v2 plugin
- Ports `3000`, `8080`, `8081`, `8761`, and `27017` available on your machine

## Run with Docker Compose

From the repository root, build the images and start the application:

```bash
docker compose up --build
```

The Java service Dockerfiles run `mvn clean package` during their image build. The frontend image installs its npm dependencies and starts the React development server. The first build may take a few minutes while Docker downloads base images and dependencies.

Open the application at **http://localhost:3000**. The service registry dashboard is available at **http://localhost:8761**.

To start the containers in the background:

```bash
docker compose up --build -d
```

View service logs with:

```bash
docker compose logs -f
```

Stop and remove the containers and network with:

```bash
docker compose down
```

Product data is stored in the named `mongo-data` volume and is retained by `docker compose down`. To also delete the stored data, use:

```bash
docker compose down --volumes
```

### Inspect MongoDB

MongoDB has no authentication configured in this local development setup. To inspect it with MongoDB Compass, connect to:

```text
mongodb://localhost:27017/inventory_db
```

The product documents are stored in the `products` collection. You can also check the container health and recent logs from a terminal:

```bash
docker compose ps
docker compose logs --tail=100 mongodb
docker compose exec mongodb mongosh inventory_db
```

## Product API

The gateway exposes the product API at `http://localhost:8080/api/products`.

List products (no authentication required):

```bash
curl http://localhost:8080/api/products
```

Create a product (HTTP Basic authentication required):

```bash
curl --user admin:admin123 \
  --header "Content-Type: application/json" \
  --data '{"name":"Hydraulic Pump","price":249.99,"stock":12}' \
  http://localhost:8080/api/products
```

Products have an ID, name, price, and stock quantity. The frontend displays the product list and includes a form for adding a product.

There is no separate login page. The frontend currently sends the demo admin credentials (`admin` / `admin123`) automatically when you submit the form; you do not need to log in first. The credentials are configured in the frontend and API gateway source code for local development only.

The frontend currently shows an “Unauthorized or server error” alert for any failed create request, including cases where a service is still starting or unavailable. If adding a product fails, check the service logs:

```bash
docker compose logs -f api-gateway product-service
```

Wait for the services to finish starting and register with Eureka, then try again. You can also check whether the gateway is responding with:

```bash
curl -i http://localhost:8080/api/products
```

> **Security:** `admin` / `admin123` is hard-coded demo authentication in the API gateway. Do not use these credentials or expose this configuration in a production deployment. Configure production credentials, TLS, and appropriate authorization before deployment.

## Build a Java service locally

Each Java service is an independent Maven project; run Maven from the relevant service directory:

```bash
cd service-registry && mvn clean package
cd ../product-service && mvn clean package
cd ../api-gateway && mvn clean package
```

Alternatively, `docker compose up --build` builds all application images, including the Java packages, without requiring Maven to be installed on the host.

## AWS deployment options

- [ECS Fargate, S3, and CloudFront](README-AWS.md) — multi-service AWS deployment managed by Terraform.
- [Single EC2 instance with Docker Compose](README-AWS-EC2.md) — simpler educational deployment with MongoDB data on a separate EBS volume.

These are separate Terraform configurations under `terraform/`. Use one architecture at a time; each has its own deployment and teardown instructions.
