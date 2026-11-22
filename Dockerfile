FROM traefik:v3

# Install gettext (envsubst) and curl for template interpolation and healthchecks
RUN apk add --no-cache gettext curl

# Create configuration directory
RUN mkdir -p /etc/traefik

# Copy static and dynamic configuration templates
COPY traefik.yml.template /etc/traefik/traefik.yml.template
COPY dynamic.yml.template /etc/traefik/dynamic.yml.template

# Copy entrypoint script (PID 1) and administrative validation script (Factor XII)
COPY entrypoint.sh /entrypoint.sh
COPY validate-config.sh /validate-config.sh

# Ensure scripts are executable
RUN chmod +x /entrypoint.sh /validate-config.sh

# Keep root user (necessary on Alpine Linux to bind privileged port 80 without extra capabilities)
USER root

# Parameterized port exposure (Factor VII)
ARG PORT_ARG=80
EXPOSE ${PORT_ARG}

# Entrypoint PID 1
ENTRYPOINT ["/entrypoint.sh"]
