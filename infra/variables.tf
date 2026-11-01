variable "regiao" {
  type    = string
  default = "us-east-1"
}

variable "nome" {
  type    = string
  default = "togglemaster"
}

variable "versao_kubernetes" {
  type    = string
  default = "1.34"
}

variable "cidr_vpc" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "bancos" {
  type = map(string)
  default = {
    auth      = "auth_db"
    flags     = "flags_db"
    targeting = "targeting_db"
  }
}

variable "servicos" {
  type    = list(string)
  default = ["auth-service", "flag-service", "targeting-service", "evaluation-service", "analytics-service"]
}
