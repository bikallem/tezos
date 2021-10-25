FROM ubuntu:20.10

ENV DEBIAN_FRONTEND noninteractive

# Get the basic stuff
RUN apt-get update && \
    apt-get -y upgrade && \
    apt-get install -y \
    sudo

# Create ubuntu user with sudo privileges
RUN useradd -ms /bin/bash ubuntu && \
    usermod -aG sudo ubuntu
# New added for disable sudo password
RUN echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# Set as default user
USER ubuntu
WORKDIR /home/ubuntu

# Install opam
RUN sudo apt install -y build-essential
RUN gcc --version
RUN mkdir test
RUN cd test
COPY g11.c .

# This doesn't generate any warning as required
# RUN gcc -c g11.c

# The below generates warning 
RUN gcc -std=gnu99 -pedantic -c g11.c

