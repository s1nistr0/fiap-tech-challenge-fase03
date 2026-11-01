terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.70" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }

  backend "s3" {
    bucket       = "tfstate-togglemaster-541754963625"
    key          = "fase3/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.regiao

  default_tags {
    tags = {
      projeto  = "techchallenge-fase3"
      gerencia = "terraform"
      ambiente = "homolog"
    }
  }
}
