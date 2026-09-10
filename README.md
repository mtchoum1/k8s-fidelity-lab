# k8s-fidelity-lab
This project uses a single Kubernetes Operator + Custom Resource Definition (CRD) called ModelInferencePipeline. As you push a feature/change through each tier, the change will pass lower levels but reveal subtle real-world failure modes (like root user restrictions or route syntax) as you climb to higher fidelity tiers.
