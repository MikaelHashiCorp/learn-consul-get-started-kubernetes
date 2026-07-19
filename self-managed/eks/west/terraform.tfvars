name              = "consul-eks"
vpc_region        = "us-west-2"
consul_version    = "v1.22.7"
node_desired_size = 3

# HC-COMPUTE-011: EDR (Uptycs) — set per deployment environment
# uptycs_update_tag: UPDATE/PROD, UPDATE/DEV, or UPDATE/NONE per IBM Tag Guide
# uptycs_owner: your team or owner email address
uptycs_update_tag = "UPDATE/NONE"
uptycs_owner      = "Mikael.Sikora@ibm.com"