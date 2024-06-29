provider "aws" {
  region = "us-east-1"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "my-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  enable_vpn_gateway = false

  tags = {
    Terraform   = "true"
    Environment = "prd"
  }
}

resource "aws_security_group" "web_sg" {
  name_prefix = "web_sg"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_s3_bucket" "my_bucket" {
  bucket = "my-website-moore"
}

resource "aws_s3_bucket_acl" "my_bucket_acl" {
  bucket = aws_s3_bucket.my_bucket.id
  acl    = "public-read"
}

resource "aws_s3_bucket_website_configuration" "my_bucket_website" {
  bucket = aws_s3_bucket.my_bucket.id

  index_document {
    suffix = "index.php"
  }
}

resource "aws_s3_object" "index_php" {
  bucket = aws_s3_bucket.my_bucket.bucket
  key    = "index.php"
  acl    = "public-read"
  source = "${path.module}./pruebas/archivo-index/index.php"
}

resource "aws_efs_file_system" "nfs" {}

resource "aws_efs_mount_target" "nfs_mount" {
  count           = length(module.vpc.public_subnets)
  file_system_id  = aws_efs_file_system.nfs.id
  subnet_id       = element(module.vpc.public_subnets, count.index)
  security_groups = [aws_security_group.web_sg.id]
}

resource "aws_instance" "web_server" {
  count         = 3
  ami           = "ami-08a0d1e16fc3f61ea"
  instance_type = "t2.micro"
  key_name      = "vockey"
  subnet_id     = element(module.vpc.public_subnets, count.index)
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd php amazon-efs-utils
              systemctl start httpd
              systemctl enable httpd
              mkdir -p /mnt/efs
              mount -t efs ${aws_efs_file_system.nfs.id}:/ /mnt/efs
              ln -s /mnt/efs/index.php /var/www/html/index.php
              aws s3 cp s3://${aws_s3_bucket.my_bucket.bucket}/index.php /mnt/efs/index.php
              EOF

  tags = {
    Name = "web-server-${count.index}"
  }
}

resource "aws_lb" "web_lb" {
  name               = "web-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = module.vpc.public_subnets

  depends_on = [module.vpc, aws_security_group.web_sg]
}

resource "aws_lb_target_group" "web_tg" {
  name     = "web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
  }

  depends_on = [aws_lb.web_lb]
}

resource "aws_lb_listener" "web_listener" {
  load_balancer_arn = aws_lb.web_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }

  depends_on = [aws_lb_target_group.web_tg]
}

resource "aws_lb_target_group_attachment" "tg_attachment" {
  count            = 3
  target_group_arn = aws_lb_target_group.web_tg.arn
  target_id        = element(aws_instance.web_server.*.id, count.index)
  port             = 80

  depends_on = [aws_instance.web_server, aws_lb_target_group.web_tg]
}

resource "aws_iam_role" "ec2_role" {
  name = "ec2_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "s3_policy" {
  name = "s3_policy"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = ["arn:aws:s3:::${aws_s3_bucket.my_bucket.id}/*"]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2_profile"
  role = aws_iam_role.ec2_role.name
}

data "aws_availability_zones" "available" {}
