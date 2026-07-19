resource "aws_lb" "gateway" {
  name               = "${var.network_resource_prefix}-gateway-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "gateway" {
  name        = "${var.network_resource_prefix}-gateway-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.gateway.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }
}

# Cognito terminates the login here; ALB passes the verified identity to the
# gateway as the signed x-amzn-oidc-data header, which gateway/server.js
# re-verifies against ALB's own public key before trusting it.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.gateway.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this.certificate_arn

  default_action {
    type  = "authenticate-cognito"
    order = 1

    authenticate_cognito {
      user_pool_arn              = aws_cognito_user_pool.this.arn
      user_pool_client_id        = aws_cognito_user_pool_client.alb.id
      user_pool_domain           = aws_cognito_user_pool_domain.this.domain
      session_cookie_name        = "AWSELBAuthSessionCookie"
      scope                      = "openid email"
      session_timeout            = 2700
      on_unauthenticated_request = "authenticate"
    }
  }

  default_action {
    type             = "forward"
    order            = 2
    target_group_arn = aws_lb_target_group.gateway.arn
  }
}
