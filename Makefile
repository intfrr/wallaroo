DOCKER_IMAGE_VERSION=$(shell git describe --tags --always)
DOCKER_IMAGE_REPO=docker.sendence.com:5043/sendence

current_dir = $(shell pwd)
docker_image_version ?= $(DOCKER_IMAGE_VERSION) ## Docker Image Tag to use
docker_image_repo ?= $(DOCKER_IMAGE_REPO) ## Docker Repository to use
arch ?= native ## Architecture to build for

ifdef arch
  ifeq (,$(filter $(arch),amd64 armhf native))
    $(error Unknown architecture "$(arch)")
  endif
endif

ifeq ($(arch),amd64)
  define PONYC
    docker run --rm -it -v $(current_dir)/$(1):$(current_dir)/$(1) -w $(current_dir)/$(1) lispmeister/rpxp \
       -U `id -u -n` \
       -u 1000 \
       -G `id -g -n` \
       -g 1000 \
       /build/bin/ponyc .
  endef
else ifeq ($(arch),armhf)
  define PONYC
    docker run --rm -it -v $(current_dir)/$(1):$(current_dir)/$(1) -w $(current_dir)/$(1) lispmeister/rpxp \
       -U `id -u -n` \
       -u 1000 \
       -G `id -g -n` \
       -g 1000 \
       /build/build.sh .
  endef
else
  define PONYC
    cd $(current_dir)/$(1) && ponyc .
  endef
endif

default: build

print-%  : ; @echo $* = $($*)

build: ## Build Pony based programs for Buffy
	$(call PONYC,spike)
	$(call PONYC,giles/receiver)
	$(call PONYC,giles/sender)

build-docker:  build ## Build docker images for Buffy
	docker build -t $(docker_image_repo)/spike.$(arch):$(docker_image_version) spike
	docker build -t $(docker_image_repo)/giles-receiver.$(arch):$(docker_image_version) giles/receiver
	docker build -t $(docker_image_repo)/giles-sender.$(arch):$(docker_image_version) giles/sender
	docker build -t $(docker_image_repo)/buffy:$(docker_image_version) buffy
	docker tag $(docker_image_repo)/buffy:$(docker_image_version) $(docker_image_repo)/buffy.$(arch):$(docker_image_version)
	docker build -t $(docker_image_repo)/dagon:$(docker_image_version) dagon
	docker tag $(docker_image_repo)/dagon:$(docker_image_version) $(docker_image_repo)/dagon.$(arch):$(docker_image_version)

push-docker: build-docker ## Push docker images for Buffy to repository
	docker push $(docker_image_repo)/spike.$(arch):$(docker_image_version)
	docker push $(docker_image_repo)/giles-receiver.$(arch):$(docker_image_version)
	docker push $(docker_image_repo)/giles-sender.$(arch):$(docker_image_version)
	docker push $(docker_image_repo)/buffy:$(docker_image_version)
	docker push $(docker_image_repo)/buffy.$(arch):$(docker_image_version)
	docker push $(docker_image_repo)/dagon:$(docker_image_version)
	docker push $(docker_image_repo)/dagon.$(arch):$(docker_image_version)

exited := $(shell docker ps -a -q -f status=exited)
untagged := $(shell (docker images | grep "^<none>" | awk -F " " '{print $$3}'))
dangling := $(shell docker images -f "dangling=true" -q)
tag := $(shell docker images | grep "$(docker_image_version)" |awk -F " " '{print $$3}')

clean: ## Cleanup docker images and compiled files for Buffy
	rm -f spike/spike spike/spike.o
	rm -f giles/receiver/receiver giles/receiver/receiver.o
	rm -f giles/sender/sender giles/sender/sender.o
ifneq ($(strip $(tag)),)
	@echo "Removing tag $(tag) image"
	docker rmi $(tag)
endif
ifneq ($(strip $(exited)),)
	@echo "Cleaning exited containers: $(exited)"
	docker rm -v $(exited)
endif
ifneq ($(strip $(dangling)),)
	@echo "Cleaning dangling images: $(dangling)"
	docker rmi $(dangling)
endif
	@echo 'Done cleaning.'

help:
	@echo 'Usage: make [option1=value] [option2=value,...] [target]'
	@echo ''
	@echo 'Options:'
	@grep -E '^[a-zA-Z_-]+ *\?=.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = "?=.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
	@grep -E 'filter.*arch.*)$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = "[(),]"}; {printf "\033[36m%-30s\033[0m %s\n", "  Valid values for " $$5 ":", $$7}'
	@echo ''
	@echo 'Targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

