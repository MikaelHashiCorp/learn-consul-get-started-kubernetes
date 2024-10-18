#!/bin/bash
# Scale up node group
aws eks update-nodegroup-config --cluster-name consul-eks-ti --nodegroup-name consul-eks-server-2024101723564156740000000f --scaling-config minSize=1,maxSize=3,desiredSize=3

# Start EC2 instances
aws ec2 start-instances --instance-ids i-0f79faa41a7f97874 i-0ecb2b7c218c2edfc i-09ad0fbbdc34e7488

# Recreate NAT Gateway and Elastic IPs (you'll need to adjust these commands based on your specific setup)
# Recreate Load Balancers (you'll need to use CloudFormation or Terraform to recreate these with the same configuration)