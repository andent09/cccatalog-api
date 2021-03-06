# List of available subnets
data "aws_subnet_ids" "subnets" {
  vpc_id = "${var.vpc_id}"
}
##############
# API SERVER #
##############

# A templated bash script that bootstraps the API server.
data "template_file" "init" {
  template = "${file("${path.module}/init.tpl")}"

  # Pass configuration variables to the script
  vars {
    database_host         = "${var.database_host}"
    database_password     = "${var.database_password}"
    django_debug_enabled  = "${var.django_debug_enabled}"
    django_secret_key     = "${var.django_secret_key}"
    git_revision          = "${var.git_revision}"
    load_balancer_url     = "${aws_alb.cccatalog-api-load-balancer.dns_name}"
    wsgi_auth_credentials = "${var.wsgi_auth_credentials}"
    aws_access_key_id     = "${var.aws_access_key_id}"
    aws_secret_access_key = "${var.aws_secret_access_key}"
    elasticsearch_url     = "${var.elasticsearch_url}"
    elasticsearch_port    = "${var.elasticsearch_port}"
    aws_region            = "${var.aws_region}"
    api_version           = "${var.api_version}"
    redis_host            = "${var.redis_host}"
    redis_password        = "${var.redis_password}"
    root_shortening_url   = "${var.root_shortening_url}"
  }
}

# API server autoscaling launch configuration
resource "aws_launch_configuration" "cccatalog-api-launch-config" {
  name_prefix              = "cccatalog-api-asg-${var.environment}-"
  image_id                 = "ami-afd15ed0"
  instance_type            = "${var.instance_type}"
  security_groups          = ["${aws_security_group.cccatalog-sg.id}",
                              "${aws_security_group.cccatalog-api-ingress.id}"]
  enable_monitoring        = "${var.enable_monitoring}"
  key_name                 = "${aws_key_pair.cccapi-admin.key_name}"
  user_data                = "${data.template_file.init.rendered}"

  lifecycle {
    create_before_destroy  = true
  }
}

# API server autoscaling group
# Changes to the launch configuration result in automated zero-downtime redeployment
resource "aws_autoscaling_group" "cccatalog-api-asg" {
  name                 = "${aws_launch_configuration.cccatalog-api-launch-config.id}"
  launch_configuration = "${aws_launch_configuration.cccatalog-api-launch-config.id}"
  min_size             = "${var.min_size}"
  max_size             = "${var.max_size}"
  min_elb_capacity     = "${var.min_size}"
  vpc_zone_identifier  = ["${data.aws_subnet_ids.subnets.ids}"]
  target_group_arns    = ["${aws_alb_target_group.ccc-api-asg-target.id}"]
  wait_for_capacity_timeout = "8m"

  tag {
    key                 = "Name"
    value               = "cccatalog-api-autoscaling-group-${var.environment}"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = "${var.environment}"
    propagate_at_launch = true
  }

  tag {
    key                 = "service"
    value               = "cccatalog-api-django"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_key_pair" "cccapi-admin" {
  key_name   = "cccapi-admin"
  public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCzocO5AKxkGVTtpmtgVd0UrpI2//v6YO8kxKZQ5t99sK0K62QG1PQj+nxFA5wCkiGNJohlvVX+Hl1ZujDLH3/G9yPaUbOA4MeDEUy3JQSxTfMVcPKVTocAldU5A/5LkxIsB+XwDY/JFr7aQq3YlwLikJ2Sb6LFaUACJWzXKMa2zTE7TvHYpJqB4UihAFVuuqQPBH5PzwXjeHJcq/zIZgnB9orMfK0Fci5YRp2wdY/RWqJwDAuTpfvaGCZmghqo0ogAmm+Dz0EPGu9jJrRvlZ7c0c1bP+eWTuHIeiXsuAN6wlkXuu8hRXRwbBdVox7ST8x8eRBUdWZZcaoeZ69dI2HZ webmaster@creativecommons.org"
}

resource "aws_security_group" "cccatalog-api-ingress" {
  name = "cccatalog-api-ingress"
  vpc_id = "${var.vpc_id}"

  # Allow incoming traffic from the load balancer and autoscale clones
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = ["${aws_security_group.cccatalog-alb-sg.id}"]
  }

  # Allow incoming SSH from the internet
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Unrestricted egress
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "cccatalog-sg" {
  name   = "cccatalog-security-group"
  vpc_id = "${var.vpc_id}"


  lifecycle {
    create_before_destroy = true
  }
}

# Public-facing load balancer
resource "aws_alb" "cccatalog-api-load-balancer" {
  name                       = "cccatalog-api-alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = ["${aws_security_group.cccatalog-sg.id}",
                                "${aws_security_group.cccatalog-alb-sg.id}"]
  enable_deletion_protection = false
  subnets                    = ["${data.aws_subnet_ids.subnets.ids}"]

  tags {
    Name        = "cccatalog-api-load-balancer-${var.environment}"
    Environment = "${var.environment}"
  }
}

resource "aws_alb_target_group" "ccc-api-asg-target" {
  name     = "ccc-api-autoscale-target"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = "${var.vpc_id}"


  health_check {
    path = "/healthcheck"
    port = 8080
  }
}

resource "aws_alb_listener" "ccc-api-asg-listener" {
  load_balancer_arn = "${aws_alb.cccatalog-api-load-balancer.id}"
  port              = 80
  protocol          = "HTTP"

  default_action {
    target_group_arn = "${aws_alb_target_group.ccc-api-asg-target.id}"
    type             = "forward"
  }
}

resource "aws_security_group" "cccatalog-alb-sg" {
  name   = "cccatalog-alb-sg"
  vpc_id = "${var.vpc_id}"

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

  tags {
    Name = "cccatalog-alb-sg"
  }
}

#######################
# URL SHORTENER PROXY #
#######################

# Templated bash script for bootstrapping link shortener proxy
data "template_file" "proxy-init" {
  template = "${file("${path.module}/proxy-init.tpl")}"
    vars {
      ccc_api_host = "${var.ccc_api_host}"
    }
}

resource "aws_security_group" "short-proxy-sg" {
  name = "short-proxy-sg"
  vpc_id = "${var.vpc_id}"

  # Allow incoming traffic from the internet
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    cidr_blocks     = ["0.0.0.0/0"]
  }

  # Allow incoming SSH from the internet
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Unrestricted egress
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "short-proxy" {
  ami                    = "ami-b70554c8"
  instance_type          = "${var.instance_type}"
  user_data              = "${data.template_file.proxy-init.rendered}"
  # Launch it on the first available subnet
  subnet_id              = "${element(data.aws_subnet_ids.subnets.ids, 0)}"
  key_name               = "cccapi-admin"
  vpc_security_group_ids = ["${aws_security_group.short-proxy-sg.id}"]

  tags {
    Name        = "short-proxy-${var.environment}"
    environment = "${var.environment}"
  }
}
