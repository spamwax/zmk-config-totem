# syntax=docker/dockerfile:1
ARG zmk_type=dev
ARG zmk_tag=3.5

FROM docker.io/zmkfirmware/zmk-${zmk_type}-arm:${zmk_tag}

ARG USERNAME=hamid
ARG USERUID=1000
ARG USERGID=1000

ENV USER_ID=$USERUID 
ENV GROUP_ID=$USERGID 
ENV USER_NAME=$USERNAME

RUN apt -y update && apt -y install jq htop neovim openssh-client shellcheck reserialize
# RUN apt install -y python3-pip
# RUN python3 -m pip install --break-system-packages remarshal


# Create the user
RUN deluser ubuntu || echo
RUN delgroup ubuntu || echo
RUN groupadd --gid $GROUP_ID $USER_NAME \
  && useradd --uid $USER_ID --gid $GROUP_ID -d /home/$USER_NAME -m $USER_NAME

RUN mkdir -p -m 0700 /home/${USERNAME}/.ssh && ssh-keyscan 192.168.13.200 >> /home/${USERNAME}/.ssh/known_hosts
RUN chown -R ${USERNAME}:${USERGID} /home/${USERNAME}
RUN --mount=type=ssh \
  ssh -q -T ${USERNAME}@192.168.13.200 ls 2>&1 | tee /hello
RUN echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCd+h7PYcF4n3FgAX7roJHMTmytsBp2/FrVZM9H+zeCMPyRWfArfMVNofyBGGtqX9z+yyDsYWAu7YlD2bjj7sHDD+PJyeNRI5lsAngGEzXHxwm3mAXUgj45Q6mgm2JS9M4c468bUd/rp8LicYdxDXYv71HdaRkkRW+O+JOvewCRoHQW8+5otoHIy3kyHSRwtkZ7qMAkDH6Q9yhvylFsAKX+Ox15whLAKVniVehIi9EMwhFSbY+/J8k8Z17aZytpz+q6ieUj5gt2b+YRHrcvoLblCVpQKeZwHTpEMhIHcpv8/1LZZ31G0p48p9r4o3JJ8ecAFSG/1E/pkWrXnc9Ga3uqWehjhI+opX0ZC1hA6LGpoNatOWU6QYXBy0qV9YRT/6AZvfYjKMzHTxb92F4TGB3WlaDhC/D4gg2eFKdXzRIF6Ay5eta1nIhGmwKyD0BRByY5dFxnW5dfMWqRoR0YA7r/2mABFh9qN+KTISx/H1wq+WJprnv3PsV9siQ0eEZk5IM= hamid@khersak" > /home/${USERNAME}/.ssh/id_rsa.pub

RUN mkdir /.ccache \
  && chown -R ${USER_ID}:${GROUP_ID} /.ccache \
  && mkdir /.cache \
  && chown -R ${USER_ID}:${GROUP_ID} /.cache
