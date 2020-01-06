An environement to manage Python AWS lambda functions.
- AMI instance to build the function
- Drone, Git (Gogs) as CI/CD tools
- Terraform to create or update the functions on AWS

Drone uses credentials/variables stored in a Vault/Consul service.

[Amazon Machine Image] (https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html "AMI")
[Drone] (https://drone.io/ "Drone")
[Terraform] (https://www.terraform.io/ "Terraform")
[Gogs] (https://gogs.io/ "Gogs")
