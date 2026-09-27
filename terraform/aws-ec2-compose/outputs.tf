output "instance_id" {
  description = "EC2 instance ID. Use it to connect with AWS Systems Manager Session Manager."
  value       = aws_instance.app.id
}

output "instance_public_ip" {
  description = "Stable Elastic IP address."
  value       = aws_eip.app.public_ip
}

output "frontend_url" {
  description = "React development server URL."
  value       = "http://${aws_eip.app.public_ip}:3000"
}

output "api_url" {
  description = "API gateway URL."
  value       = "http://${aws_eip.app.public_ip}:8080/api/products"
}

output "mongo_ebs_volume_id" {
  description = "Encrypted EBS volume that persists MongoDB data independently of the EC2 root disk."
  value       = aws_ebs_volume.mongodb.id
}

output "bootstrap_log_command" {
  description = "Command to inspect EC2 bootstrap and Compose startup logs over Session Manager."
  value       = "sudo tail -n 200 /var/log/inventory-bootstrap.log"
}
