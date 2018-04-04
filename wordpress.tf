# Deploy wordpress within ecs

# VARIABLES
variable "aws_region" {
  description = "Define aws region"
  default = "us-east-1"
}

variable "aws_profile" {
  description = "Define the aws profile with valid credentials to use"
  default = "default"
}

variable "env_tag" {
  description = "Define default env tag for your infrastructure"
  default = "testing"
}

variable "vpc_cidr_block" {
  description = "Define default ip block for the VPC"
  default = "10.0.0.0/16"
}

variable "db_name" {
  description = "Define the rds database name"
  default = "wordpress"
}

variable "db_user" {
  description = "Define the rds database default user"
  default = "admin"
}

variable "db_password" {
  description = "Define the rds database password to use"
  default = "XeiLahshu7ahthashi7ioDoH6vaebuChie"
}

# PROVIDERS
provider "aws" {
  region = "${var.aws_region}"
  profile = "${var.aws_profile}"
}

# RESOURCES

# 1) We will create a docker repository within aws, then we run packer configured to upload the image to this registry
resource "aws_ecr_repository" "wordpress" {
  name = "wordpress"

  # Capture the ecr url for feeding packer
  provisioner "local-exec" {
    command = "echo { \\\"aws_ecr_repository\\\": \\\"${self.repository_url}\\\" } > repository.json"
  }

  # Build wordpres image and push it to the created ecr.
  provisioner "local-exec" {
    command = "packer build -var-file=credentials.json -var-file=repository.json wordpress.json"
  }
}

# 2) Create VPC and subnets to use for the ecs cluster and the alb
data "aws_availability_zones" "available" {}

resource "aws_vpc" "wordpress_vpc" {
  cidr_block = "${var.vpc_cidr_block}"
  assign_generated_ipv6_cidr_block = true

  tags = {
    Name = "wordpress_vpc"
    env = "${var.env_tag}"
  }
}

# Create two subnets
resource "aws_subnet" "wordpress_subnet" {
  count = 2
  cidr_block = "${cidrsubnet(aws_vpc.wordpress_vpc.cidr_block, 8, count.index)}"
  ipv6_cidr_block = "${cidrsubnet(aws_vpc.wordpress_vpc.ipv6_cidr_block, 8, count.index)}"
  availability_zone = "${data.aws_availability_zones.available.names[count.index]}"
  vpc_id = "${aws_vpc.wordpress_vpc.id}"

  tags = {
    Name = "wordpress_${count.index}"
    env = "${var.env_tag}"
  }
}

# Create gateway and assing routes
resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.wordpress_vpc.id}"

  tags = {
    Name = "wordpress_gw"
    env = "${var.env_tag}"
  }
}

resource "aws_route" "default_route4" {
  route_table_id = "${aws_vpc.wordpress_vpc.main_route_table_id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = "${aws_internet_gateway.gw.id}"
}

resource "aws_route" "default_route6" {
  route_table_id = "${aws_vpc.wordpress_vpc.main_route_table_id}"
  destination_ipv6_cidr_block = "::/0"
  gateway_id = "${aws_internet_gateway.gw.id}"
}

# 3) Create RDS
resource "aws_db_instance" "database" {
  identifier = "database"
  allocated_storage = 20
  storage_type = "gp2"
  engine = "mariadb"
  engine_version = "10.1"
  instance_class = "db.t2.micro"
  name = "${var.db_name}"
  username = "${var.db_user}"
  password = "${var.db_password}"
  parameter_group_name = "default.mariadb10.1"
  multi_az = false
  publicly_accessible = false
  availability_zone = "${data.aws_availability_zones.available.names[0]}"
  db_subnet_group_name = "${aws_db_subnet_group.wordpress_subnet_group.id}"
  vpc_security_group_ids = [
    "${aws_security_group.wordpress_db.id}"
  ]
  final_snapshot_identifier = "wordpressdatabase"
  skip_final_snapshot = true

  tags = {
    env = "${var.env_tag}"
  }
}

resource "aws_db_subnet_group" "wordpress_subnet_group" {
  name = "wordpress_subnet_group"

  subnet_ids = [
    "${aws_subnet.wordpress_subnet.*.id}"
  ]

  tags = {
    env = "${var.env_tag}"
  }

  depends_on = [
    "aws_subnet.wordpress_subnet"
  ]
}

# Allow access only from ecs security group
resource "aws_security_group" "wordpress_db" {
  name = "wordpress_db"
  description = "wordpress rds"
  vpc_id = "${aws_vpc.wordpress_vpc.id}"

  ingress {
    from_port = 3306
    to_port = 3306
    protocol = "tcp"
    security_groups = [
      "${aws_security_group.wordpress_ecs_sg.id}"
    ]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }

  tags = {
    env = "${var.env_tag}"
  }
}

# 4.1) Create ECS Cluster
resource "aws_ecs_cluster" "wordpress_ecs" {
  name = "wordpress"
}

# 4.2) Create app load balancer
resource "aws_alb" "wordpress_alb" {
  name = "wordpressalb"
  ip_address_type = "dualstack"
  subnets = [
    "${aws_subnet.wordpress_subnet.*.id}"
  ]
  security_groups = [
    "${aws_security_group.wordpress_alb_sg.id}"
  ]

  tags = {
    env = "${var.env_tag}"
  }
}

# Target group were ecs instances will be registered for this alb
resource "aws_alb_target_group" "wordpress_tg" {
  name = "wordpress-tg"
  port = 80
  protocol = "HTTP"
  vpc_id = "${aws_vpc.wordpress_vpc.id}"
  target_type = "ip"

  health_check {
    matcher = "200,302"
  }

  tags = {
    env = "${var.env_tag}"
  }
}

# Create listener for the elb pointing to the previously created tg
resource "aws_alb_listener" "wordpress_l" {
  load_balancer_arn = "${aws_alb.wordpress_alb.id}"
  port = "80"
  protocol = "HTTP"

  default_action {
    target_group_arn = "${aws_alb_target_group.wordpress_tg.id}"
    type = "forward"
  }
}

# Would add here another alb_listener for the 443 protocol, for that I would require a domain managed by route53
# configured to use the alb as an alias.


resource "aws_security_group" "wordpress_alb_sg" {
  name = "wordpress_alb"
  description = "wordpress elb"
  vpc_id = "${aws_vpc.wordpress_vpc.id}"

  ingress {
    protocol = "tcp"
    from_port = 80
    to_port = 80
    cidr_blocks = [
      "0.0.0.0/0"
    ]
    ipv6_cidr_blocks = [
      "::/0"
    ]
  }

  //  ingress {
  //    protocol = "tcp"
  //    from_port = 443
  //    to_port = 443
  //    cidr_blocks = [
  //      "0.0.0.0/0",
  //      "::/0"
  //    ]
  //  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }

  tags = {
    env = "${var.env_tag}"
  }
}


# 4.3) Create a wordpress task
resource "aws_ecs_task_definition" "wordpress_task" {
  family = "wordpress"
  network_mode = "awsvpc"
  requires_compatibilities = [
    "FARGATE"
  ]
  cpu = 256
  memory = 512
  execution_role_arn = "${aws_iam_role.ecsTaskExecutionRole.arn}"
  container_definitions = <<DEFINITION
[
  {
    "name": "wordpress",
    "image": "${aws_ecr_repository.wordpress.repository_url}",
    "essential": true,
    "networkMode": "awsvpc",
    "portMappings": [
      {
        "containerPort": 80,
        "hostPort": 80
      }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "${aws_cloudwatch_log_group.wordpress_log.name}",
        "awslogs-region": "${var.aws_region}",
        "awslogs-stream-prefix": "ecs"
      }
    },
    "environment": [
      {
        "name": "WORDPRESS_DB_HOST",
        "value": "${aws_db_instance.database.address}"
      },
      {
        "name": "WORDPRESS_DB_NAME",
        "value": "${var.db_name}"
      },
      {
        "name": "WORDPRESS_DB_PASSWORD",
        "value": "${var.db_password}"
      },
      {
        "name": "WORDPRESS_DB_USER",
        "value": "${var.db_user}"
      }
    ]
  }
]
DEFINITION
}

# Define a group log to send logs genearted by the container
resource "aws_cloudwatch_log_group" "wordpress_log" {
  name = "/ecs/wordpress"
  retention_in_days = 1

  tags = {
    env = "${var.env_tag}"
  }
}

# ecs default policy
resource "aws_iam_role_policy" "ecsTaskExecutionPolicy" {
  name = "ecsTaskExecutionPolicy"
  role = "${aws_iam_role.ecsTaskExecutionRole.id}"
  policy = <<ROLEPOLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
ROLEPOLICY
}

resource "aws_iam_role" "ecsTaskExecutionRole" {
  name = "ecsTaskExecutionRole"
  assume_role_policy = <<ROLEPOLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
ROLEPOLICY
}


#4.4) Create the service within the cluster
resource "aws_ecs_service" "wordpress_service" {
  name = "wordpress"
  cluster = "${aws_ecs_cluster.wordpress_ecs.id}"
  task_definition = "${aws_ecs_task_definition.wordpress_task.arn}"
  desired_count = 1
  launch_type = "FARGATE"
  health_check_grace_period_seconds = 120

  network_configuration {
    security_groups = [
      "${aws_security_group.wordpress_ecs_sg.id}"
    ]
    subnets = [
      "${aws_subnet.wordpress_subnet.*.id}"
    ]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = "${aws_alb_target_group.wordpress_tg.id}"
    container_name = "wordpress"
    container_port = 80
  }

  depends_on = [
    "aws_alb_listener.wordpress_l",
  ]
}

# Define sg for ecs containers, allowing acess only from the alb
resource "aws_security_group" "wordpress_ecs_sg" {
  name = "wordpress_ecs"
  description = "wordpress ecs"
  vpc_id = "${aws_vpc.wordpress_vpc.id}"

  ingress {
    protocol = "tcp"
    from_port = 80
    to_port = 80
    security_groups = [
      "${aws_security_group.wordpress_alb_sg.id}"
    ]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }

  tags = {
    env = "${var.env_tag}"
  }
}

output "wordpress_endpoint" {
  value = "${aws_alb.wordpress_alb.dns_name}"
}
