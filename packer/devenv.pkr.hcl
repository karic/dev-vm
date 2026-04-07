packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

source "amazon-ebs" "devenv" {
  ami_name      = "devenv-{{timestamp}}"
  instance_type = var.instance_type
  region        = var.aws_region

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"] # Canonical
  }

  ssh_username = "ubuntu"
}

build {
  sources = ["source.amazon-ebs.devenv"]

  provisioner "file" {
    source      = "../ansible"
    destination = "/tmp/ansible"
  }

  provisioner "file" {
    source      = "files/"
    destination = "/tmp/packer-files"
  }

  provisioner "file" {
    source      = "scripts/devenv-boot.sh"
    destination = "/tmp/packer-files/devenv-boot.sh"
  }

  provisioner "shell" {
    script = "scripts/setup.sh"
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  }
}
