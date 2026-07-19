# Cognito User Pool + Hosted UI, fronting the ALB's authenticate-cognito
# listener action. Self-signup is enabled; the Pre-SignUp Lambda (lambda.tf)
# rejects any email domain not in var.allowed_signup_email_domains.
resource "aws_cognito_user_pool" "this" {
  name = var.project_name

  auto_verified_attributes = ["email"]
  username_attributes      = ["email"]

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  password_policy {
    minimum_length    = 12
    require_uppercase = true
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
  }

  lambda_config {
    pre_sign_up = aws_lambda_function.pre_signup.arn
  }
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${var.project_name}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.this.id
}

resource "aws_cognito_user_pool_client" "alb" {
  name         = "${var.project_name}-alb"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = true

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  allowed_oauth_flows_user_pool_client = true
  supported_identity_providers         = ["COGNITO"]

  callback_urls = ["https://${var.domain_name}/oauth2/idpresponse"]
  logout_urls   = ["https://${var.domain_name}/"]

  explicit_auth_flows = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
}

data "aws_caller_identity" "current" {}
