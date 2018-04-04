Description
===========

Deploys wordpress within aws ecs using terraform, it will also create a test mardiadb rds to use with it.
It is a ready to use terraform/packer example, that:

1. Creates an ecr repository witin aws
2. Repackages wordpress docker container using packer and uploads it to ecr (the original idea was to show a sample packer deployment provisioned with ansible).
3. Creates all necessary VPC's and subnets
4. Provisions a MariaDB rds database (free tier).
5. Creates an ECS cluster, with a wordpress task definition and its service. (Currently is configured to use fargate, unfortunately fargate is not under the free tier).


Instructions
============

These script will use by default your aws credentials found within ~/.aws/credentials
Also, you need to create a credentials.json file, and add a key with the profile you which to chose (used default by default).

credentials.json to use:
{
  "aws_profile": "your_profile",
  "dbpassword": "database_password_to_use"
}

Questions
=========
Any questions, pull-requests, wathever, are more than welcome.


