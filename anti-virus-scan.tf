#
# Lambda Function: Anti-Virus Scanning
#

#
# IAM
#

data "aws_iam_policy_document" "assume_role_scan" {
  statement {
    effect = "Allow"

    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "main_scan" {
  # Allow creating and writing CloudWatch logs for Lambda function.
  statement {
    sid = "WriteCloudWatchLogs"

    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.name_scan}:*"]
  }

  statement {
    sid = "s3AntiVirusScan"

    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:PutObjectTagging",
      "s3:PutObjectVersionTagging",
    ]

    resources = ["${formatlist("%s/*", data.aws_s3_bucket.main_scan.*.arn)}"]
  }

  statement {
    sid = "s3AntiVirusDefinitions"

    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectTagging",
    ]

    resources = ["arn:aws:s3:::${var.av_definition_s3_bucket}/${var.av_definition_s3_prefix}/*"]
  }

  statement {
    sid = "kmsDecrypt"

    effect = "Allow"

    actions = [
      "kms:Decrypt",
    ]

    resources = ["${formatlist("%s/*", data.aws_s3_bucket.main_scan.*.arn)}"]
  }

  statement {
    sid = "snsPublish"

    effect = "Allow"

    actions = [
      "sns:Publish",
    ]

    resources = ["${compact(list(var.av_scan_start_sns_arn, var.av_status_sns_arn))}"]
  }
}

resource "aws_iam_role" "main_scan" {
  name               = "lambda-${local.name_scan}"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role_scan.json}"
}

resource "aws_iam_role_policy" "main_scan" {
  name = "lambda-${local.name_scan}"
  role = "${aws_iam_role.main_scan.id}"

  policy = "${data.aws_iam_policy_document.main_scan.json}"
}

#
# S3 Event
#

data "aws_s3_bucket" "main_scan" {
  count  = "${length(var.av_scan_buckets)}"
  bucket = "${var.av_scan_buckets[count.index]}"
}

resource "aws_s3_bucket_notification" "main_scan" {
  count  = "${length(var.av_scan_buckets)}"
  bucket = "${element(data.aws_s3_bucket.main_scan.*.id, count.index)}"

  lambda_function {
    id                  = "${element(data.aws_s3_bucket.main_scan.*.id, count.index)}"
    lambda_function_arn = "${aws_lambda_function.main_scan.arn}"
    events              = ["s3:ObjectCreated:*"]
  }
}

#
# CloudWatch Logs
#

resource "aws_cloudwatch_log_group" "main_scan" {
  # This name must match the lambda function name and should not be changed
  name              = "/aws/lambda/${local.name_scan}"
  retention_in_days = "${var.cloudwatch_logs_retention_days}"

  tags = {
    Name = "${local.name_scan}"
  }
}

#
# Lambda Function
#

resource "aws_lambda_function" "main_scan" {
  depends_on = ["aws_cloudwatch_log_group.main_scan"]

  s3_bucket = "${var.lambda_s3_bucket}"
  s3_key    = "${var.lambda_package}/${var.lambda_version}/${var.lambda_package}.zip"

  function_name = "${local.name_scan}"
  role          = "${aws_iam_role.main_scan.arn}"
  handler       = "scan.lambda_handler"
  runtime       = "python2.7"
  memory_size   = "1024"
  timeout       = "300"

  environment {
    variables = {
      AV_DEFINITION_S3_BUCKET        = "${var.av_definition_s3_bucket}"
      AV_DEFINITION_S3_PREFIX        = "${var.av_definition_s3_prefix}"
      AV_SCAN_START_SNS_ARN          = "${var.av_scan_start_sns_arn}"
      AV_STATUS_SNS_ARN              = "${var.av_status_sns_arn}"
      AV_STATUS_SNS_PUBLISH_CLEAN    = "${var.av_status_sns_publish_clean}"
      AV_STATUS_SNS_PUBLISH_INFECTED = "${var.av_status_sns_publish_infected}"
    }
  }

  tags = {
    Name = "${local.name_scan}"
  }
}

resource "aws_lambda_permission" "main_scan" {
  count = "${length(var.av_scan_buckets)}"

  statement_id = "${local.name_scan}"

  action        = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.main_scan.function_name}"

  principal = "s3.amazonaws.com"

  source_account = "${data.aws_caller_identity.current.account_id}"
  source_arn     = "${element(data.aws_s3_bucket.main_scan.*.arn, count.index)}"

  statement_id = "${local.name_scan}-${element(data.aws_s3_bucket.main_scan.*.id, count.index)}"
}
