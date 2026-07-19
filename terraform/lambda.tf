# Pre-SignUp Lambda trigger: rejects self-registration from any email domain
# not in var.allowed_signup_email_domains.
data "archive_file" "pre_signup" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/pre-signup"
  output_path = "${path.module}/.build/pre-signup.zip"
}

resource "aws_iam_role" "pre_signup_lambda" {
  name = "${var.project_name}-presignup-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "pre_signup_lambda_basic" {
  role       = aws_iam_role.pre_signup_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "pre_signup" {
  function_name    = "${var.project_name}-presignup"
  role             = aws_iam_role.pre_signup_lambda.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  timeout          = 5
  filename         = data.archive_file.pre_signup.output_path
  source_code_hash = data.archive_file.pre_signup.output_base64sha256

  environment {
    variables = {
      ALLOWED_SIGNUP_EMAIL_DOMAINS = join(",", var.allowed_signup_email_domains)
    }
  }
}

resource "aws_lambda_permission" "cognito_invoke_pre_signup" {
  statement_id  = "cognito-presignup-invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pre_signup.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.this.arn
}
