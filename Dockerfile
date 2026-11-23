FROM traefik:v3

# Install gettext (envsubst), curl and dos2unix for template interpolation, healthchecks and LF conversion
RUN apk add --no-cache gettext curl dos2unix

# Create configuration directory
RUN mkdir -p /etc/traefik

# Copy static and dynamic configuration templates
COPY traefik.yml.template /etc/traefik/traefik.yml.template
COPY dynamic.yml.template /etc/traefik/dynamic.yml.template

# Copy entrypoint script (PID 1) and administrative validation script (Factor XII)
COPY entrypoint.sh /entrypoint.sh
COPY validate-config.sh /validate-config.sh

# Ensure scripts have Linux LF line endings and are executable
RUN dos2unix /entrypoint.sh /validate-config.sh && \
    chmod +x /entrypoint.sh /validate-config.sh

# Keep root user (necessary on Alpine Linux to bind privileged port 80 without extra capabilities)
USER root

# Parameterized port exposure (Factor VII)
ARG PORT_ARG=80
EXPOSE ${PORT_ARG}

# Entrypoint PID 1
ENTRYPOINT ["/entrypoint.sh"]
