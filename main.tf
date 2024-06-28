provider "aws" {
  region = "us-west-2"
}

resource "aws_s3_bucket" "my_bucket" {
  bucket = "my-website-bucket"
  acl    = "public-read"

  website {
    index_document = "index.html"
  }
}

resource "aws_s3_bucket_object" "index_html" {
  bucket = aws_s3_bucket.my_bucket.bucket
  key    = "index.html"
  source = "path/to/index.html"
  acl    = "public-read"
}

resource "aws_efs_file_system" "nfs" {}

resource "aws_efs_mount_target" "nfs_mount" {
  count           = length(aws_subnet.my_subnet.*.id)
  file_system_id  = aws_efs_file_system.nfs.id
  subnet_id       = element(aws_subnet.my_subnet.*.id, count.index)
  security_groups = [aws_security_group.nfs_sg.id]
}

resource "aws_security_group" "nfs_sg" {
  name_prefix = "nfs_sg"
  
  ingress {
    from_port   = 2049
    to_port     = 2049
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

resource "aws_security_group" "lb_sg" {
  name_prefix = "lb_sg"

  ingress {
    from_port   = 80
    to_port     = 80
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

resource "aws_security_group" "ec2_sg" {
  name_prefix = "ec2_sg"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups = [aws_security_group.lb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_launch_template" "web_server" {
  name_prefix = "web-server"

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  image_id      = "ami-0c55b159cbfafe1f0"  # Amazon Linux 2 AMI
  instance_type = "t2.micro"

  key_name = "my-key"

  security_group_names = [aws_security_group.ec2_sg.name]

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd amazon-efs-utils
              systemctl start httpd
              systemctl enable httpd
              echo "<h1>Welcome to my website</h1>" > /var/www/html/index.html
              mkdir -p /mnt/efs
              mount -t efs ${aws_efs_file_system.nfs.id}:/ /mnt/efs
              ln -s /mnt/efs/index.html /var/www/html/index.html
              EOF
}

resource "aws_autoscaling_group" "web_asg" {
  desired_capacity     = 3
  max_size             = 3
  min_size             = 3
  launch_template {
    id      = aws_launch_template.web_server.id
    version = "$Latest"
  }

  vpc_zone_identifier = aws_subnet.my_subnet.*.id

  tag {
    key                 = "Name"
    value               = "web-server"
    propagate_at_launch = true
  }
}

resource "aws_lb" "web_lb" {
  name               = "web-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = aws_subnet.my_subnet.*.id
}

resource "aws_lb_target_group" "web_tg" {
  name     = "web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.my_vpc.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "web_listener" {
  load_balancer_arn = aws_lb.web_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}

resource "aws_lb_target_group_attachment" "asg_attachment" {
  target_group_arn = aws_lb_target_group.web_tg.arn
  target_id        = aws_autoscaling_group.web_asg.id
  port             = 80
}

resource "aws_vpc" "my_vpc" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "my_subnet" {
  count = 3
  vpc_id = aws_vpc.my_vpc.id
  cidr_block = cidrsubnet(aws_vpc.my_vpc.cidr_block, 8, count.index)
}

resource "aws_iam_role" "ec2_role" {
  name = "ec2_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_policy_attachment" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2_profile"
  role = aws_iam_role.ec2_role.name
}
