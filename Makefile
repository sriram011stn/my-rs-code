init:
	terraform init

plan:
	terraform plan

apply2:
	terraform apply -target=null_resource.kind_cluster -auto-approve
	kubectl config use-context kind-tf-immu
	terraform apply -auto-approve

apply:
	terraform apply -auto-approve

gate:
	./runtime-gate.sh kube-system

destroy:
	terraform destroy -auto-approve || true
	-kind delete cluster --name tf-immu || true
