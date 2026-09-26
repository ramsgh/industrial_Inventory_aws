locals {
  availability_zones = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  java_services = {
    service-registry = {
      port        = 8761
      cpu         = 256
      memory      = 512
      environment = []
    }
    product-service = {
      port   = 8081
      cpu    = 256
      memory = 512
      environment = [
        {
          name  = "SPRING_DATA_MONGODB_URI"
          value = "mongodb://mongodb.inventory.internal:27017/inventory_db"
        },
        {
          name  = "EUREKA_CLIENT_SERVICEURL_DEFAULTZONE"
          value = "http://service-registry.inventory.internal:8761/eureka/"
        }
      ]
    }
    api-gateway = {
      port   = 8080
      cpu    = 256
      memory = 512
      environment = [
        {
          name  = "EUREKA_CLIENT_SERVICEURL_DEFAULTZONE"
          value = "http://service-registry.inventory.internal:8761/eureka/"
        }
      ]
    }
  }

  service_ports = merge(
    { for name, service in local.java_services : name => service.port },
    { mongodb = 27017 }
  )
}

resource "aws_vpc" "app" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "app" {
  vpc_id = aws_vpc.app.id
}

resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.app.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.availability_zones[count.index]
  map_public_ip_on_launch = true
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.app.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.app.id
  }
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "load_balancer" {
  name        = "${var.project_name}-alb"
  description = "Allow CloudFront origin traffic to the application load balancer."
  vpc_id      = aws_vpc.app.id

  ingress {
    description     = "CloudFront origin-facing HTTPS/HTTP requests"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "tasks" {
  name        = "${var.project_name}-tasks"
  description = "Allow application traffic only from the load balancer and other application tasks."
  vpc_id      = aws_vpc.app.id

  ingress {
    description     = "Gateway traffic from the load balancer"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.load_balancer.id]
  }

  ingress {
    description = "Internal service discovery and database traffic"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "efs" {
  name        = "${var.project_name}-efs"
  description = "Allow encrypted NFS traffic from application tasks."
  vpc_id      = aws_vpc.app.id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.tasks.id]
  }
}

resource "aws_efs_file_system" "mongodb" {
  encrypted       = true
  creation_token  = "${var.project_name}-mongodb"
  throughput_mode = "elastic"
}

resource "aws_efs_access_point" "mongodb" {
  file_system_id = aws_efs_file_system.mongodb.id

  posix_user {
    uid = 999
    gid = 999
  }

  root_directory {
    path = "/mongodb"

    creation_info {
      owner_uid   = 999
      owner_gid   = 999
      permissions = "0755"
    }
  }
}

resource "aws_efs_mount_target" "mongodb" {
  count           = var.az_count
  file_system_id  = aws_efs_file_system.mongodb.id
  subnet_id       = aws_subnet.public[count.index].id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_iam_role" "ecs_execution" {
  name = "${var.project_name}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task" {
  name = "${var.project_name}-ecs-task"

  assume_role_policy = aws_iam_role.ecs_execution.assume_role_policy
}

resource "aws_iam_role_policy" "mongodb_efs" {
  name = "${var.project_name}-mongodb-efs"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "elasticfilesystem:ClientMount",
        "elasticfilesystem:ClientWrite"
      ]
      Resource = aws_efs_file_system.mongodb.arn
      Condition = {
        StringEquals = {
          "elasticfilesystem:AccessPointArn" = aws_efs_access_point.mongodb.arn
        }
        Bool = {
          "aws:SecureTransport" = "true"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "ecs_exec" {
  name = "${var.project_name}-ecs-exec"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_cloudwatch_log_group" "services" {
  for_each          = toset(concat(keys(local.java_services), ["mongodb"]))
  name              = "/ecs/${var.project_name}/${each.key}"
  retention_in_days = 14
}

resource "aws_ecr_repository" "services" {
  for_each             = local.java_services
  name                 = "${var.project_name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecs_cluster" "app" {
  name = var.project_name
}

resource "aws_service_discovery_private_dns_namespace" "app" {
  name = "inventory.internal"
  vpc  = aws_vpc.app.id
}

resource "aws_service_discovery_service" "app" {
  for_each = local.service_ports
  name     = each.key

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.app.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_ecs_task_definition" "java" {
  for_each                 = local.java_services
  family                   = "${var.project_name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = each.key
    image     = "${aws_ecr_repository.services[each.key].repository_url}:${var.image_tag}"
    essential = true
    portMappings = [{
      name          = "application"
      containerPort = each.value.port
      hostPort      = each.value.port
      protocol      = "tcp"
      appProtocol   = "http"
    }]
    environment = each.value.environment
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.services[each.key].name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "ecs"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "mongodb" {
  family                   = "${var.project_name}-mongodb"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  volume {
    name = "mongodb-data"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.mongodb.id
      transit_encryption = "ENABLED"

      authorization_config {
        access_point_id = aws_efs_access_point.mongodb.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([{
    name      = "mongodb"
    image     = "mongo:7.0"
    essential = true
    portMappings = [{
      name          = "mongodb"
      containerPort = 27017
      hostPort      = 27017
      protocol      = "tcp"
    }]
    mountPoints = [{
      sourceVolume  = "mongodb-data"
      containerPath = "/data/db"
      readOnly      = false
    }]
    healthCheck = {
      command     = ["CMD", "mongosh", "--quiet", "mongodb://localhost:27017/admin", "--eval", "db.runCommand({ ping: 1 }).ok"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.services["mongodb"].name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "mongodb" {
  name                   = "mongodb"
  cluster                = aws_ecs_cluster.app.id
  task_definition        = aws_ecs_task_definition.mongodb.arn
  desired_count          = var.desired_count
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true
  }

  service_registries {
    registry_arn   = aws_service_discovery_service.app["mongodb"].arn
    container_name = "mongodb"
    container_port = 27017
  }

  depends_on = [aws_efs_mount_target.mongodb]
}

resource "aws_ecs_service" "java" {
  for_each               = local.java_services
  name                   = each.key
  cluster                = aws_ecs_cluster.app.id
  task_definition        = aws_ecs_task_definition.java[each.key].arn
  desired_count          = var.desired_count
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true
  }

  service_registries {
    registry_arn   = aws_service_discovery_service.app[each.key].arn
    container_name = each.key
    container_port = each.value.port
  }

  dynamic "load_balancer" {
    for_each = each.key == "api-gateway" ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.gateway.arn
      container_name   = each.key
      container_port   = each.value.port
    }
  }

  depends_on = [aws_lb_listener.http]
}

resource "aws_lb" "app" {
  name               = substr("${var.project_name}-alb", 0, 32)
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.load_balancer.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "gateway" {
  name        = substr("${var.project_name}-gateway", 0, 32)
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.app.id

  health_check {
    enabled             = true
    path                = "/api/products"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 5
    timeout             = 10
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }
}

resource "aws_s3_bucket" "frontend" {
  bucket = "${var.project_name}-${data.aws_caller_identity.current.account_id}-${var.aws_region}-frontend"
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.project_name}-frontend"
  description                       = "Private S3 access for the inventory frontend."
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_origin_request_policy" "api" {
  name    = "${var.project_name}-api"
  comment = "Forward API authorization, CORS, content type, and query strings to the gateway."

  headers_config {
    header_behavior = "whitelist"

    headers {
      items = [
        "Authorization",
        "Origin",
        "Access-Control-Request-Method",
        "Access-Control-Request-Headers",
        "Content-Type"
      ]
    }
  }

  cookies_config {
    cookie_behavior = "none"
  }

  query_strings_config {
    query_string_behavior = "all"
  }
}

resource "aws_cloudfront_distribution" "app" {
  enabled             = true
  comment             = "${var.project_name} frontend and API"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "frontend-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  origin {
    domain_name = aws_lb.app.dns_name
    origin_id   = "application-load-balancer"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "frontend-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "application-load-balancer"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = aws_cloudfront_origin_request_policy.api.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1.2_2021"
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCloudFrontReadOnly"
      Effect = "Allow"
      Principal = {
        Service = "cloudfront.amazonaws.com"
      }
      Action   = "s3:GetObject"
      Resource = "${aws_s3_bucket.frontend.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.app.arn
        }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.frontend]
}
