provider "aws" {
    region = "us-east-1"
}

terraform {
  backend "s3" {
    bucket = "myawsbucket-valentin1987"
    key    = "terraform_vpc-assignment.tfstate"
    region = "us-east-1"
  }
}


# =============== DATA ====================
data "aws_availability_zones" "available" {}
data "aws_ami" "latest_linux" {
  owners = ["amazon"]
  most_recent = true
  filter {
    name = "name"
    values = ["amzn2-ami-hvm-2.0.20211001.1-x86_64-gp2"]
  }
}

# =============== VPC AND IGW ====================

resource "aws_vpc" "wordpress_vpc" {
    cidr_block = var.vpc_cidr
    tags = {
      Name = "${var.project} - VPC"
    }
}

resource "aws_internet_gateway" "wordpress_igw" {
    vpc_id = aws_vpc.wordpress_vpc.id
    tags = {
      Name = "${var.project} - IGW"
    } 
}

# =============== PUBLIC SUBNET AND ROUTE TABLE ====================

resource "aws_subnet" "wordpress_public_subnet" {
    count = length(var.public_subnet_cidrs)
    vpc_id     = aws_vpc.wordpress_vpc.id
    cidr_block = element(var.public_subnet_cidrs, count.index)
    availability_zone = data.aws_availability_zones.available.names[count.index]
    map_public_ip_on_launch = true 
    tags = {
      Name = "${var.project} - Public - ${count.index+1}"
    }
  }

resource "aws_route_table" "wordpress_rt" {
    vpc_id = aws_vpc.wordpress_vpc.id
    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.wordpress_igw.id
        }
    tags = {
        Name = "${var.project} - Public Route Table"
    }
}

resource "aws_route_table_association" "wordpress_rt" {
  count = length(aws_subnet.wordpress_public_subnet[*].id)
  route_table_id = aws_route_table.wordpress_rt.id
  subnet_id = element(aws_subnet.wordpress_public_subnet[*].id, count.index)
}

# ================== NAT GATEWAY AND ELASTIC IP ====================
resource "aws_eip" "wordpress_eip" {

    vpc      = true
    tags = {
        Name = "${var.project} - EPI "
  }
}
resource "aws_nat_gateway" "wordpress_nat" {
    allocation_id = aws_eip.wordpress_eip.id
    subnet_id     = aws_subnet.wordpress_public_subnet[0].id

    tags = {
        Name = "${var.project} - NAT Gateway"
    }
    depends_on = [aws_internet_gateway.wordpress_igw]
}

# ================== PRIVATE SUBNET AND ROUTING ====================

resource "aws_subnet" "wordpress_private_subnet" {
    count = length(var.private_subnet_cidrs)
    vpc_id     = aws_vpc.wordpress_vpc.id
    cidr_block = element(var.private_subnet_cidrs, count.index)
    availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.project} - Private - ${count.index+1}"
  }
}

resource "aws_route_table" "wordpress_rt_private" {
    
    vpc_id = aws_vpc.wordpress_vpc.id
    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_nat_gateway.wordpress_nat.id
        }
    tags = {
        Name = "${var.project} - Private Route Table "
    }
}

resource "aws_route_table_association" "wordpress_rt_private" {
  count = length(aws_subnet.wordpress_private_subnet[*].id)
  route_table_id = aws_route_table.wordpress_rt_private.id
  subnet_id = element(aws_subnet.wordpress_private_subnet[*].id, count.index)
}

# ============== EC2 AND SECURITY GROUP =============

  resource "aws_security_group" "wordpress-ec2-sg" {
  name        = "WordPress EC2 SG"
  description = "WordPress EC2 SG"
  vpc_id      = aws_vpc.wordpress_vpc.id

  dynamic "ingress" {
    for_each = ["80", "443", "22"]
    content {
      description      = "ports"
      from_port        = ingress.value
      to_port          = ingress.value
      protocol         = "tcp"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = []
      prefix_list_ids = []
      security_groups = []
      self = false
    }
  } 
  egress = [ 
    {
      description      = "ssh from everywhere"
      from_port        = 0
      to_port          = 0
      protocol         = "-1"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = []
      prefix_list_ids = []
      security_groups = []
      self = false
    }
  ]
  tags = {
    Name = "${var.project} - EC2 SG"
  }
}

resource "aws_key_pair" "mykey" {
  key_name   = "ssh-key"
  public_key = file(var.PATH_TO_PUBLIC_KEY)
}

resource "aws_instance" "wordpress-ec2" {
  ami = data.aws_ami.latest_linux.id
  instance_type = "t2.micro"
  vpc_security_group_ids = [aws_security_group.wordpress-ec2-sg.id]
  subnet_id = aws_subnet.wordpress_public_subnet[0].id 
  key_name      = aws_key_pair.mykey.key_name
  user_data = file("user_data.sh")
  tags = {
    Name = "${var.project} - WebServer"
  }
  connection {
    host        = coalesce(self.public_ip, self.private_ip)
    type        = "ssh"
    user        = var.INSTANCE_USERNAME
    private_key = file(var.PATH_TO_PRIVATE_KEY)
  }  
}
# ============== DB INSTANCE AND SECURITY GROUP =============

resource "aws_security_group" "wordpress-rsg-sg" {
  name        = "WordPress DB SG"
  description = "WordPress DB SG"
  vpc_id      = aws_vpc.wordpress_vpc.id

  ingress = [{
      description      = "mysql"
      from_port        = 3306
      to_port          = 3306
      protocol         = "tcp"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = []
      prefix_list_ids = []
      security_groups = [aws_security_group.wordpress-ec2-sg.id]
      self = false
  } ]
  egress = [ 
    {
      description      = "ssh from everywhere"
      from_port        = 0
      to_port          = 0
      protocol         = "-1"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = []
      prefix_list_ids = []
      security_groups = []
      self = false
    }
  ]
  tags = {
    Name = "${var.project} - DB SG"
  }
  depends_on = [
    aws_security_group.wordpress-ec2-sg,
  ]
}

resource "aws_db_subnet_group" "db_subnet" {  
  name       = "db_subnet"  
  subnet_ids = aws_subnet.wordpress_private_subnet[*].id 
  }

resource "aws_db_instance" "wordpress-db" {
  identifier = "mydb"
  allocated_storage    = 10
  engine               = "mysql"
  engine_version       = "5.7"
  instance_class       = "db.t2.micro"
  name                 = "wordpress"
  username             = var.db_username
  password             = var.db_password
  parameter_group_name = "default.mysql5.7"
  storage_type = "gp2"
  skip_final_snapshot  = true
  vpc_security_group_ids = [aws_security_group.wordpress-rsg-sg.id]
  db_subnet_group_name = aws_db_subnet_group.db_subnet.name
  tags = {
    "Name" = "${var.project} - DB Server"
  }
}