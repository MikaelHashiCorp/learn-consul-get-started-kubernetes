#!/bin/bash
# Scale down node group
aws eks update-nodegroup-config --cluster-name consul-eks-ti --nodegroup-name consul-eks-server-2024101723564156740000000f --scaling-config minSize=0,maxSize=0,desiredSize=0

# Stop EC2 instances
aws ec2 stop-instances --instance-ids i-0f79faa41a7f97874 i-0ecb2b7c218c2edfc i-09ad0fbbdc34e7488

# Release Elastic IPs
aws ec2 release-address --allocation-id eipalloc-047eec0b2774a4067
aws ec2 release-address --allocation-id eipalloc-05beb8af76464786f

# Delete NAT Gateway
aws ec2 delete-nat-gateway --nat-gateway-id nat-0d5d3bff471646be8

# Delete Load Balancers
aws elbv2 delete-load-balancer --load-balancer-arn arn:aws:elasticloadbalancing:us-west-2:189504808923:loadbalancer/a1f2377dde5d04c04946686544b6ec30
aws elbv2 delete-load-balancer --load-balancer-arn arn:aws:elasticloadbalancing:us-west-2:189504808923:loadbalancer/acd091255bd074d20807feb092e5c86e

# Delete unattached EBS volumes
aws ec2 delete-volume --volume-id vol-0f00bbebd97bafb60
aws ec2 delete-volume --volume-id vol-0d41ab2f7bf394762
aws ec2 delete-volume --volume-id vol-016d878f59ad1f904
