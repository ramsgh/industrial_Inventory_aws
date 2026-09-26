output "frontend_url" {
  description = "HTTPS URL for the frontend and same-origin API."
  value       = "https://${aws_cloudfront_distribution.app.domain_name}"
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID for cache invalidations."
  value       = aws_cloudfront_distribution.app.id
}

output "frontend_bucket_name" {
  description = "Private S3 bucket where the React build is uploaded."
  value       = aws_s3_bucket.frontend.id
}

output "ecr_repository_urls" {
  description = "ECR repository URLs for the Java services."
  value = {
    for name, repository in aws_ecr_repository.services : name => repository.repository_url
  }
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.app.name
}

output "load_balancer_dns_name" {
  description = "ALB origin DNS name. The ALB security group only accepts CloudFront origin traffic."
  value       = aws_lb.app.dns_name
}
