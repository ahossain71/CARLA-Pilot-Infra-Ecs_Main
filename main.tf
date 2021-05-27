# defining the s3 bucket to store the infrastructure terraform state file
#terraform {
#    backend "s3" {
#        bucket = "carla-pilot"
#        key    = "state.tfstate"
#    }
#}

# defining the provider
provider "aws" {
    region = "us-east-1"
}

# defining the infrastructure
#vpc
resource "aws_vpc" "carla_vpc" {
    cidr_block = "10.0.0.0/16"
    enable_dns_support   = true
    enable_dns_hostnames = true
    tags       = {
        Name = "carla_vpc"
    }
}

#internet gateway
resource "aws_internet_gateway" "internet_gateway" {
    vpc_id = aws_vpc.carla_vpc.id
}

#public subnets01
resource "aws_subnet" "pub_subnet01" {
    vpc_id                  = aws_vpc.carla_vpc.id
    cidr_block              = "10.0.0.0/24"
    availability_zone       = "us-east-1a"
    tags       = {
        Name = "pub_subnet01"
    }
}

#public subnets02
resource "aws_subnet" "pub_subnet02" {
    vpc_id                  = aws_vpc.carla_vpc.id
    cidr_block              = "10.0.1.0/24"
    availability_zone       = "us-east-1b"
    tags       = {
        Name = "pub_subnet02"
    }
}

#private subnets01
resource "aws_subnet" "prv_subnet01" {
    vpc_id                  = aws_vpc.carla_vpc.id
    cidr_block              = "10.0.2.0/24"
    availability_zone       = "us-east-1a"
    tags       = {
        Name = "prv_subnet01"
    }
}

#private subnets02
resource "aws_subnet" "prv_subnet02" {
    vpc_id                  = aws_vpc.carla_vpc.id
    cidr_block              = "10.0.3.0/24"
    availability_zone      = "us-east-1b"
    tags      = {
        Name = "prv_subnet02"
    }
}

#route table
resource "aws_route_table" "carla_rtbl" {
    vpc_id = aws_vpc.carla_vpc.id

    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.internet_gateway.id
    }
}

#route_table_association
resource "aws_route_table_association" "route_table_association" {
    subnet_id      = aws_subnet.pub_subnet01.id
    route_table_id = aws_route_table.carla_rtbl.id
}

#security security_groups
resource "aws_security_group" "ec2_cluster_sg" {
    vpc_id      = aws_vpc.carla_vpc.id

    ingress {
        from_port       = 22
        to_port         = 22
        protocol        = "tcp"
        cidr_blocks     = ["0.0.0.0/0"]
    }
    ingress {
        from_port       = 443
        to_port         = 443
        protocol        = "tcp"
        cidr_blocks     = ["0.0.0.0/0"]
    }
    ingress {
        from_port       = 3000
        to_port         = 3000
        protocol        = "tcp"
        cidr_blocks     = ["0.0.0.0/0"]
    }
    egress {
        from_port       = 0
        to_port         = 65535
        protocol        = "tcp"
        cidr_blocks     = ["0.0.0.0/0"]
    }
}

#rds security group
resource "aws_security_group" "rds_sg" {
    vpc_id      = aws_vpc.carla_vpc.id

    ingress {
        protocol        = "tcp"
        from_port       = 5432
        to_port         = 5432
        cidr_blocks     = ["10.0.0.0/24","10.0.1.0/24"]
        security_groups = [aws_security_group.ec2_cluster_sg.id]
    }

    egress {
        from_port       = 0
        to_port         = 65535
        protocol        = "tcp"
        cidr_blocks     = ["0.0.0.0/0"]
    }
}

#iam role definition for the ecs agent
data "aws_iam_policy_document" "ecs_agent" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_agent" {
  name               = "ecs-agent"
  assume_role_policy = data.aws_iam_policy_document.ecs_agent.json
}

resource "aws_iam_role_policy_attachment" "ecs_agent" {
  role       = aws_iam_role.ecs_agent.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_agent" {
  name = "ecs-agent"
  role = aws_iam_role.ecs_agent.name
}

#definition of launch configiration template
resource "aws_launch_configuration" "ecs_launch_config" {
    image_id             = "ami-0742b4e673072066f"
    iam_instance_profile = aws_iam_instance_profile.ecs_agent.name
    security_groups      = [aws_security_group.ec2_cluster_sg.id]
    instance_type        = "t3.medium"
    user_data            = <<-EOF
    #!/bin/bash
    echo ECS_CLUSTER=carla_pilot_cluster >> /etc/ecs/ecs.config
    yum update -y
    amazon-linux-extras install docker
    service docker start
    usermod -a -G docker ec2-user
    chconfig docker on
    cd ~/opt/webserver/CARLA-Pilot
    aws s3 cp s3://carla-pilot/carla-pilot-images/CARLA-Pilot-Proto02.tar ./CARLA-Pilot-Proto02.tar
    docker load < CARLA-Pilot-Proto02.tar
    accountid=aws sts get-caller-identity
    docker tag carla_pilot_prototype02:latest $accountid.dkr.ecr.us-east-1.amazonaws.com/carla_pilot_prototype02:latest"
    docker push  $accountid.dkr.ecr.us-east-1.amazonaws.com/carla_pilot_prototype02:latest
    EOF
}

#definirion of auto scaling group
resource "aws_autoscaling_group" "failure_analysis_ecs_asg" {
    name                      = "asg"
    vpc_zone_identifier       = [aws_subnet.pub_subnet01.id]
    launch_configuration      = aws_launch_configuration.ecs_launch_config.name
    desired_capacity          = 1
    min_size                  = 1
    max_size                  = 2
    health_check_grace_period = 300
    health_check_type         = "EC2"
}

resource "aws_db_subnet_group" "db_subnet_group" {
    subnet_ids  = [aws_subnet.prv_subnet01.id, aws_subnet.prv_subnet02.id]
}

#database definition of 
resource "aws_db_instance" "mypostgresql" {
  allocated_storage        = 5 # gigabytes
  backup_retention_period  = 2   # in days
  db_subnet_group_name     = aws_db_subnet_group.db_subnet_group.id
  engine                   = "postgres"
  engine_version           = "12.5"
  identifier               = "mypostgresql"
  instance_class           = "db.t3.micro"
  multi_az                 = false
  name                     = "mypostgresql"
  #parameter_group_name    = "mydbparamgroup1" # if you have tuned it
 #password                 = "${trimspace(file("${path.module}/secrets/mydb1-password.txt"))}"
  password                 = "carlapass"
  username                 = "carlaadmin"
  port                     = 5432
  publicly_accessible      = false
  storage_encrypted        = true # you should always do this
  storage_type             = "gp2"
 #vpc_security_group_ids   = ["${aws_security_group.mydb1.id}"]
  vpc_security_group_ids=[aws_security_group.rds_sg.id, aws_security_group.ec2_cluster_sg.id]
}

#definition of ecr repo
resource "aws_ecr_repository" "carla_pilot_ecr-repo" {
    name  = "carla_pilot_ecr-repo"
}

#definition of ecs cluster
resource "aws_ecs_cluster" "carla_pilot_cluster" {
    name  = "carla_pilot_cluster"
}

#defining the template file for the task and variable
data "template_file" "task_definition_template" {
  template = file("${path.module}/task_definition.json.tpl")
  vars = {
    REPOSITORY_URL = aws_ecr_repository.carla_pilot_ecr-repo.repository_url
  }
}

#carla-pilot task definitian that would be executed to launch the container_definitions
resource "aws_ecs_task_definition" "task_definition" {
  family                = "carla_pilot"
  container_definitions = data.template_file.task_definition_template.rendered
}

#carla-pilot ecs service definition
resource "aws_ecs_service" "carla_pilot_service" {
  name            = "carla_pilot_service"
  cluster         = aws_ecs_cluster.carla_pilot_cluster.id
  task_definition = aws_ecs_task_definition.task_definition.arn
  desired_count   = 2
}

#output definition for mypostgresql database url
output "mypostgresql_endpoint" {
    value = aws_db_instance.mypostgresql.endpoint
}

#output definition for ecr repository url
output "ecr_repository_carla_pilo_endpoint" {
    value = aws_ecr_repository.carla_pilot_ecr-repo.repository_url
}