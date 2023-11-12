# syntax=docker/dockerfile:1
ARG zmk_type=dev
ARG zmk_tag=stable

FROM docker.io/zmkfirmware/zmk-${zmk_type}-arm:${zmk_tag}

ARG USERNAME=hamid
ARG USERUID=1000
ARG USERGID=1000

ENV USER_ID=$USERUID 
ENV GROUP_ID=$USERGID 
ENV USER_NAME=$USERNAME

RUN apt -y update && apt -y install jq htop
# RUN apt install -y python3-pip
RUN python3 -m pip install remarshal

# Create the user
RUN groupadd --gid $GROUP_ID $USER_NAME \
      && useradd --uid $USER_ID --gid $GROUP_ID -d /home/$USER_NAME -m $USER_NAME

      RUN mkdir /.ccache \
        && chown -R ${USER_ID}:${GROUP_ID} /.ccache \
        && mkdir /.cache \
        && chown -R ${USER_ID}:${GROUP_ID} /.cache \
        && ls -la /.cache /.ccache \
        && ls -la /home/$USER_NAME \
        && ls -lad /home/$USER_NAME

