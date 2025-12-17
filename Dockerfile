# check=skip=InvalidBaseImagePlatform
FROM jrottenberg/ffmpeg:8.0-ubuntu2404

LABEL maintainer="hnrobert"
LABEL description="Automatically compress and optimize images in commits and pull requests"

# Avoid prompts from apt
ENV DEBIAN_FRONTEND=noninteractive

# Install required packages
RUN apt-get update && apt-get install -y \
    git \
    bc \
    file \
    && rm -rf /var/lib/apt/lists/*

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Set working directory
WORKDIR /github/workspace

ENTRYPOINT ["/entrypoint.sh"]
