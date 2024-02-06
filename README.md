# 610deploy

Bash script to deploy Google Cloud Platform components as a simple IaC strategy.

It is a wrapper around the gcloud SDK that generates the commands to run from
a .yml config file.

This makes it really convenient in CICD pipelines for dynamic injection of configuration
values to the deployment, for example: 
- Adding labels to reflect versions deployed
- Add environment related prefixes or suffixes
- Overlay configurations for environment-dependent values (prod vs dev)
