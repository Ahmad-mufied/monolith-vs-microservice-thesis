"""
budget_nuclear_shutdown.py
--------------------------
Lambda function triggered via SNS when AWS Budget hits threshold.

Shutdown sequence:
1. Delete EKS node groups (all clusters)
2. Delete EKS clusters (all clusters)
3. Stop RDS instances (all instances)
4. Delete NAT Gateways (in VPC)
5. Release unassociated Elastic IPs

Environment Variables:
  EKS_CLUSTERS     : comma-separated cluster names
  RDS_INSTANCE_IDS : comma-separated RDS identifiers
  VPC_ID           : VPC ID for NAT GW discovery
  DELETE_EKS       : "true" to delete clusters, "false" to skip
  AWS_REGION       : AWS region
"""

import boto3
import os
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION", "ap-southeast-1")
EKS_CLUSTERS = os.environ.get("EKS_CLUSTERS", "")
RDS_INSTANCE_IDS = os.environ.get("RDS_INSTANCE_IDS", "")
DELETE_EKS = os.environ.get("DELETE_EKS", "true").lower() == "true"
VPC_ID = os.environ.get("VPC_ID", "")

eks_client = boto3.client("eks", region_name=REGION)
rds_client = boto3.client("rds", region_name=REGION)
ec2_client = boto3.client("ec2", region_name=REGION)


def delete_eks_nodegroups(cluster_name):
    """Delete all node groups in a cluster. Returns list of nodegroup names."""
    logger.info(f"[EKS] Listing node groups for cluster: {cluster_name}")
    try:
        response = eks_client.list_nodegroups(clusterName=cluster_name)
        nodegroups = response.get("nodegroups", [])

        if not nodegroups:
            logger.info(f"[EKS] No node groups found in {cluster_name}.")
            return []

        for ng in nodegroups:
            logger.info(f"[EKS] Deleting node group '{ng}' in {cluster_name}...")
            eks_client.delete_nodegroup(clusterName=cluster_name, nodegroupName=ng)
            logger.info(f"[EKS] Delete requested for node group '{ng}'.")

        return nodegroups

    except eks_client.exceptions.ResourceNotFoundException:
        logger.warning(f"[EKS] Cluster '{cluster_name}' not found, skipping.")
        return []
    except Exception as e:
        logger.error(f"[EKS] Error listing node groups for {cluster_name}: {e}")
        return []


def wait_for_nodegroups_deleted(cluster_name, nodegroups):
    """Wait for all node groups to be deleted."""
    for ng in nodegroups:
        try:
            logger.info(f"[EKS] Waiting for node group '{ng}' to be deleted...")
            waiter = eks_client.get_waiter("nodegroup_deleted")
            waiter.wait(
                clusterName=cluster_name,
                nodegroupName=ng,
                WaiterConfig={"Delay": 15, "MaxAttempts": 40},
            )
            logger.info(f"[EKS] Node group '{ng}' deleted.")
        except Exception as e:
            logger.error(f"[EKS] Timeout waiting for '{ng}' deletion: {e}")


def delete_eks_clusters(clusters_str):
    """Delete EKS node groups then clusters."""
    if not clusters_str:
        logger.warning("[EKS] EKS_CLUSTERS not set, skipping.")
        return

    clusters = [c.strip() for c in clusters_str.split(",") if c.strip()]

    # Step 1: Delete all node groups
    all_nodegroups = {}
    for cluster in clusters:
        ngs = delete_eks_nodegroups(cluster)
        if ngs:
            all_nodegroups[cluster] = ngs

    # Step 2: Wait for node groups to be fully deleted
    for cluster, ngs in all_nodegroups.items():
        wait_for_nodegroups_deleted(cluster, ngs)

    # Step 3: Delete clusters
    if DELETE_EKS:
        for cluster in clusters:
            try:
                logger.info(f"[EKS] Deleting cluster '{cluster}'...")
                eks_client.delete_cluster(name=cluster)
                logger.info(f"[EKS] Cluster '{cluster}' deletion requested.")
            except eks_client.exceptions.ResourceNotFoundException:
                logger.warning(f"[EKS] Cluster '{cluster}' not found, skipping.")
            except Exception as e:
                logger.error(f"[EKS] Error deleting cluster '{cluster}': {e}")
    else:
        logger.info("[EKS] DELETE_EKS=false, skipping cluster deletion.")


def stop_rds_instances(instance_ids_str):
    """Stop RDS instances."""
    if not instance_ids_str:
        logger.warning("[RDS] RDS_INSTANCE_IDS not set, skipping.")
        return

    instance_ids = [i.strip() for i in instance_ids_str.split(",") if i.strip()]

    for db_id in instance_ids:
        logger.info(f"[RDS] Stopping instance: {db_id}")
        try:
            rds_client.stop_db_instance(DBInstanceIdentifier=db_id)
            logger.info(f"[RDS] Stop requested for '{db_id}'.")
        except rds_client.exceptions.InvalidDBInstanceStateFault:
            logger.warning(f"[RDS] '{db_id}' not in stoppable state.")
        except rds_client.exceptions.DBInstanceNotFoundFault:
            logger.warning(f"[RDS] '{db_id}' not found.")
        except Exception as e:
            logger.error(f"[RDS] Error stopping '{db_id}': {e}")


def delete_nat_gateways(vpc_id):
    """Delete NAT Gateways and release their Elastic IPs."""
    if not vpc_id:
        logger.warning("[NAT] VPC_ID not set, skipping.")
        return

    logger.info(f"[NAT] Looking for NAT Gateways in VPC: {vpc_id}")

    nat_eip_alloc_ids = []

    try:
        response = ec2_client.describe_nat_gateways(
            Filters=[
                {"Name": "vpc-id", "Values": [vpc_id]},
                {"Name": "state", "Values": ["available", "pending"]},
            ]
        )
        nat_gateways = response.get("NatGateways", [])

        if not nat_gateways:
            logger.info("[NAT] No active NAT Gateways found.")
            return

        for nat in nat_gateways:
            nat_id = nat["NatGatewayId"]
            for addr in nat.get("NatGatewayAddresses", []):
                alloc_id = addr.get("AllocationId")
                if alloc_id:
                    nat_eip_alloc_ids.append(alloc_id)

            logger.info(f"[NAT] Deleting NAT Gateway: {nat_id}")
            ec2_client.delete_nat_gateway(NatGatewayId=nat_id)
            logger.info(f"[NAT] Delete requested for '{nat_id}'.")

    except Exception as e:
        logger.error(f"[NAT] Error deleting NAT Gateways: {e}")

    # Release EIPs from deleted NAT GWs
    for alloc_id in nat_eip_alloc_ids:
        try:
            ec2_client.release_address(AllocationId=alloc_id)
            logger.info(f"[NAT] Released EIP '{alloc_id}'.")
        except Exception as e:
            logger.error(f"[NAT] Error releasing EIP '{alloc_id}': {e}")

    # Release any remaining unassociated EIPs
    try:
        addresses = ec2_client.describe_addresses(
            Filters=[{"Name": "domain", "Values": ["vpc"]}]
        )
        for addr in addresses.get("Addresses", []):
            if "AssociationId" not in addr:
                alloc_id = addr.get("AllocationId")
                if alloc_id and alloc_id not in nat_eip_alloc_ids:
                    logger.info(f"[NAT] Releasing unassociated EIP '{alloc_id}'...")
                    ec2_client.release_address(AllocationId=alloc_id)
    except Exception as e:
        logger.error(f"[NAT] Error releasing unassociated EIPs: {e}")


def lambda_handler(event, context):
    logger.info("=== BUDGET THRESHOLD REACHED - NUCLEAR SHUTDOWN ===")
    logger.info(f"Event: {json.dumps(event)}")

    try:
        if "Records" in event:
            sns_message = event["Records"][0]["Sns"]["Message"]
            logger.info(f"SNS Message: {sns_message}")
    except Exception:
        pass

    results = {}

    logger.info("STEP 1/3 - Deleting EKS node groups and clusters...")
    delete_eks_clusters(EKS_CLUSTERS)
    results["eks"] = "deletion_requested"

    logger.info("STEP 2/3 - Stopping RDS instances...")
    stop_rds_instances(RDS_INSTANCE_IDS)
    results["rds"] = "stop_requested"

    logger.info("STEP 3/3 - Deleting NAT Gateways and releasing EIPs...")
    delete_nat_gateways(VPC_ID)
    results["nat_gateways"] = "delete_requested"

    logger.info(f"=== SHUTDOWN COMPLETE === Results: {json.dumps(results)}")
    return {"statusCode": 200, "body": json.dumps(results)}
