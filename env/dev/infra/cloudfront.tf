import {
  to = aws_cloudfront_distribution.frontend
  id = var.cloudfront_distribution_id
}

import {
  to = aws_s3_bucket.frontend
  id = var.cloudfront_frontend_bucket_name
}

import {
  to = aws_s3_bucket_public_access_block.frontend
  id = var.cloudfront_frontend_bucket_name
}

import {
  to = aws_cloudfront_origin_access_control.frontend_s3
  id = var.cloudfront_frontend_oac_id
}

resource "aws_s3_bucket" "frontend" {
  bucket = var.cloudfront_frontend_bucket_name

  tags = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "frontend_s3" {
  name                              = var.cloudfront_frontend_oac_name
  description                       = "BaseLink frontend S3 OAC"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  comment             = "BaseLink frontend distribution"
  default_root_object = "index.html"
  http_version        = "http2"
  is_ipv6_enabled     = true
  price_class         = "PriceClass_200"
  retain_on_delete    = true
  web_acl_id          = aws_wafv2_web_acl.cloudfront.arn

  origin {
    origin_id                = "baselink-frontend-s3-origin"
    domain_name              = "${aws_s3_bucket.frontend.bucket}.s3.${var.aws_region}.amazonaws.com"
    connection_attempts      = 3
    connection_timeout       = 10
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend_s3.id

    s3_origin_config {
      origin_access_identity = ""
    }
  }

  origin {
    origin_id   = "baselink-dev-api-alb"
    domain_name = var.cloudfront_api_origin_domain_name
    origin_path = ""

    custom_header {
      name  = var.cloudfront_origin_verify_header_name
      value = var.cloudfront_origin_verify_header_value
    }

    connection_attempts = 3
    connection_timeout  = 10

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_keepalive_timeout = 5
      origin_protocol_policy   = "http-only"
      origin_read_timeout      = 30
      origin_ssl_protocols     = ["SSLv3", "TLSv1", "TLSv1.1", "TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "baselink-frontend-s3-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = var.cloudfront_frontend_cache_policy_id
    compress               = true
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "baselink-dev-api-alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD", "OPTIONS"]
    cache_policy_id          = var.cloudfront_api_cache_policy_id
    compress                 = true
    origin_request_policy_id = var.cloudfront_api_origin_request_policy_id
  }

  custom_error_response {
    error_caching_min_ttl = 0
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
  }

  custom_error_response {
    error_caching_min_ttl = 0
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1"
  }

  tags = local.common_tags

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_policy_document" "frontend_bucket" {
  statement {
    sid     = "AllowCloudFrontRead"
    actions = ["s3:GetObject"]

    resources = [
      "${aws_s3_bucket.frontend.arn}/*"
    ]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.frontend.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_bucket.json
}
