#
# Copyright (C) Original Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

SHELL := /bin/bash
NAME := jx
GO := $(shell command -v vgo || (go get -u golang.org/x/vgo > /dev/null && command -v vgo))
VERSION := $(shell cat pkg/version/VERSION)
#ROOT_PACKAGE := $(shell $(GO) list .)
ROOT_PACKAGE := github.com/jenkins-x/jx
GO_VERSION := $(shell $(GO) version | sed -e 's/^[^0-9.]*\([0-9.]*\).*/\1/')
#PACKAGE_DIRS := pkg cmd
PACKAGE_DIRS := $(shell $(GO) list ./... | grep -v /vendor/)
PKGS := $(shell go list ./... | grep -v /vendor | grep -v generated)


GO_DEPENDENCIES := cmd/*/*.go cmd/*/*/*.go pkg/*/*.go pkg/*/*/*.go pkg/*//*/*/*.go

REV        := $(shell git rev-parse --short HEAD 2> /dev/null  || echo 'unknown')
BRANCH     := $(shell git rev-parse --abbrev-ref HEAD 2> /dev/null  || echo 'unknown')
BUILD_DATE := $(shell date +%Y%m%d-%H:%M:%S)
BUILDFLAGS := -ldflags \
  " -X $(ROOT_PACKAGE)/pkg/version.Version=$(VERSION)\
		-X $(ROOT_PACKAGE)/pkg/version.Revision='$(REV)'\
		-X $(ROOT_PACKAGE)/pkg/version.Branch='$(BRANCH)'\
		-X $(ROOT_PACKAGE)/pkg/version.BuildDate='$(BUILD_DATE)'\
		-X $(ROOT_PACKAGE)/pkg/version.GoVersion='$(GO_VERSION)'"
CGO_ENABLED = 0

VENDOR_DIR=vendor

all: build

check: fmt build test

build: $(GO_DEPENDENCIES)
	CGO_ENABLED=$(CGO_ENABLED) $(GO) build $(BUILDFLAGS) -o build/$(NAME) cmd/jx/jx.go

test: 
	CGO_ENABLED=$(CGO_ENABLED) $(GO) test $(PACKAGE_DIRS) -test.v

#	CGO_ENABLED=$(CGO_ENABLED) $(GO) test github.com/jenkins-x/jx/cmds

test1:
	CGO_ENABLED=$(CGO_ENABLED) $(GO) test $(PACKAGE_DIRS) -test.v -run $(TEST)

testbin:
	CGO_ENABLED=$(CGO_ENABLED) $(GO) test -c github.com/jenkins-x/jx/pkg/jx/cmd -o build/jx-test

debugtest1: testbin
	cd pkg/jx/cmd && dlv --listen=:2345 --headless=true --api-version=2 exec ../../../build/jx-test -- -test.run $(TEST)

full: $(PKGS)

install: $(GO_DEPENDENCIES)
	GOBIN=${GOPATH}/bin $(GO) install $(BUILDFLAGS) cmd/jx/jx.go

fmt:
	@FORMATTED=`$(GO) fmt $(PACKAGE_DIRS)`
	@([[ ! -z "$(FORMATTED)" ]] && printf "Fixed unformatted files:\n$(FORMATTED)") || true

arm:
	CGO_ENABLED=$(CGO_ENABLED) GOOS=linux GOARCH=arm $(GO) build $(BUILDFLAGS) -o build/$(NAME)-arm cmd/jx/jx.go

win:
	CGO_ENABLED=$(CGO_ENABLED) GOOS=windows GOARCH=amd64 $(GO) build $(BUILDFLAGS) -o build/$(NAME).exe cmd/jx/jx.go

bootstrap: vendoring

vendoring:
	go get -u golang.org/x/vgo

release: check
	rm -rf build release && mkdir build release
	for os in linux darwin ; do \
		CGO_ENABLED=$(CGO_ENABLED) GOOS=$$os GOARCH=amd64 $(GO) build $(BUILDFLAGS) -o build/$$os/$(NAME) cmd/jx/jx.go ; \
	done
	CGO_ENABLED=$(CGO_ENABLED) GOOS=windows GOARCH=amd64 $(GO) build $(BUILDFLAGS) -o build/$(NAME)-windows-amd64.exe cmd/jx/jx.go
	zip --junk-paths release/$(NAME)-windows-amd64.zip build/$(NAME)-windows-amd64.exe README.md LICENSE
	CGO_ENABLED=$(CGO_ENABLED) GOOS=linux GOARCH=arm $(GO) build $(BUILDFLAGS) -o build/arm/$(NAME) cmd/jx/jx.go

	docker system prune -f
	docker build --ulimit nofile=90000:90000 -t docker.io/jenkinsxio/$(NAME):$(VERSION) .
	docker push docker.io/jenkinsxio/$(NAME):$(VERSION)

	chmod +x build/darwin/$(NAME)
	chmod +x build/linux/$(NAME)
	chmod +x build/arm/$(NAME)

	cd ./build/darwin; tar -zcvf ../../release/jx-darwin-amd64.tar.gz jx
	cd ./build/linux; tar -zcvf ../../release/jx-linux-amd64.tar.gz jx
	cd ./build/arm; tar -zcvf ../../release/jx-linux-arm.tar.gz jx

	go get -u github.com/progrium/gh-release
	gh-release checksums sha256
	gh-release create jenkins-x/$(NAME) $(VERSION) master $(VERSION)

	jx step changelog  --header-file docs/dev/changelog-header.md --version $(VERSION)

	updatebot push-version --kind brew jx $(VERSION)
	updatebot push-version --kind docker JX_VERSION $(VERSION)
	updatebot push-regex -r "\s*release = \"(.*)\"" -v $(VERSION) config.toml
	updatebot update-loop

	echo "Updating the JX CLI reference docs"
	git clone https://github.com/jenkins-x/jx-docs.git
	cd jx-docs/content/commands; \
		../../../build/linux/jx create docs; \
		git config credential.helper store; \
		git add *; \
		git commit --allow-empty -a -m "updated jx commands from $(VERSION)"; \
		git push origin

clean:
	rm -rf build release

linux:
	CGO_ENABLED=$(CGO_ENABLED) GOOS=linux GOARCH=amd64 $(GO) build $(BUILDFLAGS) -o build/linux/jx cmd/jx/jx.go

docker: linux
	docker build --no-cache -t rawlingsj/jx:dev35 .
	docker push rawlingsj/jx:dev35

docker-go: linux Dockerfile.builder-go
	docker build --no-cache -t builder-go -f Dockerfile.builder-go .

docker-maven: linux Dockerfile.builder-maven
	docker build --no-cache -t builder-maven -f Dockerfile.builder-maven .

docker-pipeline: linux
	docker build -t rawlingsj/builder-base:dev . -f Dockerfile-pipeline

docker-dev: build linux
	docker images | grep -v REPOSITORY | awk '{print $$1}' | uniq -u | grep jenkinsxio | awk '{print $$1":latest"}' | xargs -L1 docker pull
	docker build --no-cache -t $(DOCKER_HUB_USER)/jx:dev .
	docker push $(DOCKER_HUB_USER)/jx:dev
	docker build --no-cache -t $(DOCKER_HUB_USER)/builder-base:dev -f Dockerfile.builder-base .
	docker push $(DOCKER_HUB_USER)/builder-base:dev
	docker build --no-cache -t $(DOCKER_HUB_USER)/builder-maven:dev -f Dockerfile.builder-maven .
	docker push $(DOCKER_HUB_USER)/builder-maven:dev

docker-dev-all: build linux
	docker images | grep -v REPOSITORY | awk '{print $$1}' | uniq -u | grep jenkinsxio | awk '{print $$1":latest"}' | xargs -L1 docker pull
	docker build --no-cache -t $(DOCKER_HUB_USER)/jx:dev .
	docker push $(DOCKER_HUB_USER)/jx:dev
	docker build --no-cache -t $(DOCKER_HUB_USER)/builder-base:dev -f Dockerfile.builder-base .
	docker push $(DOCKER_HUB_USER)/builder-base:dev
	docker build --no-cache -t $(DOCKER_HUB_USER)/builder-go:dev -f Dockerfile.builder-go .
	docker push $(DOCKER_HUB_USER)/builder-go:dev
	docker build --no-cache -t $(DOCKER_HUB_USER)/builder-gradle:dev -f Dockerfile.builder-gradle .
	docker push $(DOCKER_HUB_USER)/builder-gradle:dev
	docker build --no-cache -t $(DOCKER_HUB_USER)/builder-maven:dev -f Dockerfile.builder-maven .
	docker push $(DOCKER_HUB_USER)/builder-maven:dev
	docker build --no-cache -t $(DOCKER_HUB_USER)/builder-rust:dev -f Dockerfile.builder-rust .
	docker push $(DOCKER_HUB_USER)/builder-rust:dev
	docker build --no-cache -t $(DOCKER_HUB_USER)/builder-scala:dev -f Dockerfile.builder-scala .
	docker push $(DOCKER_HUB_USER)/builder-scala:dev
	docker build --no-cache -t $(DOCKER_HUB_USER)/builder-swift:dev -f Dockerfile.builder-swift .
	docker push $(DOCKER_HUB_USER)/builder-swift:dev
	docker build --no-cache -t $(DOCKER_HUB_USER)/builder-terraform:dev -f Dockerfile.builder-terraform .
	docker push $(DOCKER_HUB_USER)/builder-terraform:dev
	docker build --no-cache -t $(DOCKER_HUB_USER)/builder-nodejs:dev -f Dockerfile.builder-nodejs .
	docker push $(DOCKER_HUB_USER)/builder-nodejs:dev
	docker build --no-cache -t $(DOCKER_HUB_USER)/builder-python:dev -f Dockerfile.builder-python .
	docker push $(DOCKER_HUB_USER)/builder-python:dev
	docker build --no-cache -t $(DOCKER_HUB_USER)/builder-python2:dev -f Dockerfile.builder-python2 .
	docker push $(DOCKER_HUB_USER)/builder-python2:dev
	docker build --no-cache -t $(DOCKER_HUB_USER)/builder-ruby:dev -f Dockerfile.builder-ruby .
	docker push $(DOCKER_HUB_USER)/builder-ruby:dev

.PHONY: release clean arm

preview:
	docker build --no-cache -t docker.io/jenkinsxio/builder-maven:SNAPSHOT-JX-$(BRANCH_NAME)-$(BUILD_NUMBER) -f Dockerfile.builder-maven .
	docker push docker.io/jenkinsxio/builder-maven:SNAPSHOT-JX-$(BRANCH_NAME)-$(BUILD_NUMBER)
	docker build --no-cache -t docker.io/jenkinsxio/builder-go:SNAPSHOT-JX-$(BRANCH_NAME)-$(BUILD_NUMBER) -f Dockerfile.builder-go .
	docker push docker.io/jenkinsxio/builder-go:SNAPSHOT-JX-$(BRANCH_NAME)-$(BUILD_NUMBER)
	docker build --no-cache -t docker.io/jenkinsxio/builder-nodejs:SNAPSHOT-JX-$(BRANCH_NAME)-$(BUILD_NUMBER) -f Dockerfile.builder-nodejs .
	docker push docker.io/jenkinsxio/builder-nodejs:SNAPSHOT-JX-$(BRANCH_NAME)-$(BUILD_NUMBER)

FGT := $(GOPATH)/bin/fgt
$(FGT):
	go get github.com/GeertJohan/fgt


LINTFLAGS:=-min_confidence 1.1

GOLINT := $(GOPATH)/bin/golint
$(GOLINT):
	go get github.com/golang/lint/golint

#	@echo "FORMATTING"
#	@$(FGT) gofmt -l=true $(GOPATH)/src/$@/*.go

$(PKGS): $(GOLINT) $(FGT)
	@echo "LINTING"
	@$(FGT) $(GOLINT) $(LINTFLAGS) $(GOPATH)/src/$@/*.go
	@echo "VETTING"
	@go vet -v $@
	@echo "TESTING"
	@go test -v $@

.PHONY: lint
lint: vendor | $(PKGS) $(GOLINT) # ❷
	@cd $(BASE) && ret=0 && for pkg in $(PKGS); do \
	    test -z "$$($(GOLINT) $$pkg | tee /dev/stderr)" || ret=1 ; \
	done ; exit $$ret

.PHONY: vet
vet: tools.govet
	@echo "--> checking code correctness with 'go vet' tool"
	@go vet ./...


tools.govet:
	@go tool vet 2>/dev/null ; if [ $$? -eq 3 ]; then \
		echo "--> installing govet"; \
		go get golang.org/x/tools/cmd/vet; \
	fi

GOSEC := $(GOPATH)/bin/gosec
$(GOSEC):
	go get github.com/securego/gosec/cmd/gosec/...

.PHONY: sec
sec: $(GOSEC)
	@echo "SECURITY"
	@mkdir -p scanning
	$(GOSEC) -fmt=yaml -out=scanning/results.yaml ./...


