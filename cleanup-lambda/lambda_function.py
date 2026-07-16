import os
import boto3
from datetime import datetime, timezone


def lambda_handler(event, context):
    dry_run = event.get("dry_run", os.environ.get("DRY_RUN", "true")).lower() == "true"
    mode = "DRY RUN" if dry_run else "LIVE"
    print(f"Running in {mode} mode")

    ec2 = boto3.client("ec2")

    response = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Project", "Values": ["aap-on-demand"]},
            {"Name": "tag-key", "Values": ["ExpiresAt"]},
            {"Name": "instance-state-name", "Values": ["running", "stopped"]},
        ]
    )

    now = datetime.now(timezone.utc)
    expired = []

    for reservation in response["Reservations"]:
        for instance in reservation["Instances"]:
            tags = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}
            expires_at = tags.get("ExpiresAt", "")
            try:
                expiry = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
            except ValueError:
                print(f"Skipping {instance['InstanceId']}: invalid ExpiresAt={expires_at}")
                continue

            if expiry < now:
                name = tags.get("Name", "unnamed")
                owner = tags.get("owner", "unknown")
                age = str(now - expiry).split(".")[0]
                print(f"  EXPIRED: {instance['InstanceId']} ({name}, owner={owner}), expired {expires_at} ({age} ago)")
                expired.append(instance["InstanceId"])

    if expired and not dry_run:
        ec2.terminate_instances(InstanceIds=expired)
        print(f"Terminated {len(expired)} instance(s)")
    elif expired:
        print(f"[DRY RUN] Would terminate {len(expired)} instance(s): {expired}")
    else:
        print("No expired instances found")

    return {"mode": mode, "would_terminate" if dry_run else "terminated": expired}
