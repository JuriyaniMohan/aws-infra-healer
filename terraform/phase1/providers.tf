provider "aws" {
   region = var.aws_region
 
   default_tags {
     tags = {
     Project	= "self-infra-healer"
     ManagedBy  = "Terraform"
     Phase	= "1"
     Owner	= "Mohan"
     }
    }
}
