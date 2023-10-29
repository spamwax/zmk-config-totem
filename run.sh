#!/usr/bin/env /usr/bin/bash

export FOO="fuckyeah"

# USER_ID=$(id -u) GROUP_ID=$(id -g) docker-compose --env-file ./env.list up build
USER_ID=$(id -u) GROUP_ID=$(id -g) docker-compose --env-file ./env.list run --rm build
