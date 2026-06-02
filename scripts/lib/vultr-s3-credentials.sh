#!/usr/bin/env bash

load_vultr_s3_credentials() {
  : "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set in env/vultr.env for Vultr k6 S3 uploads}"
  : "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set in env/vultr.env for Vultr k6 S3 uploads}"
}

