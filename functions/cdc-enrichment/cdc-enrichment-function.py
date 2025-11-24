#!/usr/bin/env python3
"""
CDC Message Enrichment Function for Pulsar
Enriches Debezium CDC events with additional metadata and computed fields
"""
import json
from datetime import datetime
from pulsar import Function

class CDCEnrichmentFunction(Function):
    """
    Enriches CDC messages from Debezium with:
    - Human-readable timestamps
    - Operation type labels
    - Message processing metadata
    - Data quality indicators
    """

    def process(self, input_bytes, context):
        try:
            # Parse the incoming CDC message
            # Handle both string and bytes input
            if isinstance(input_bytes, str):
                message = json.loads(input_bytes)
            else:
                message = json.loads(input_bytes.decode('utf-8'))

            # Create enriched message with original data
            enriched = {
                "original": message,
                "enrichment": {}
            }

            # Add operation type enrichment
            op = message.get("op", "unknown")
            op_labels = {
                "c": "CREATE",
                "u": "UPDATE",
                "d": "DELETE",
                "r": "READ"
            }
            enriched["enrichment"]["operation"] = {
                "code": op,
                "label": op_labels.get(op, "UNKNOWN"),
                "is_mutation": op in ["c", "u", "d"]
            }

            # Add timestamp enrichment
            ts_ms = message.get("ts_ms")
            if ts_ms:
                enriched["enrichment"]["timestamps"] = {
                    "event_time_ms": ts_ms,
                    "event_time_iso": datetime.fromtimestamp(ts_ms / 1000.0).isoformat(),
                    "processing_time_iso": datetime.utcnow().isoformat()
                }

            # Add source metadata enrichment
            source = message.get("source", {})
            if source:
                enriched["enrichment"]["source_metadata"] = {
                    "database": source.get("db"),
                    "schema": source.get("schema"),
                    "table": source.get("table"),
                    "connector": source.get("connector"),
                    "version": source.get("version"),
                    "is_snapshot": source.get("snapshot") == "true"
                }

            # Add data quality indicators
            after = message.get("after")
            before = message.get("before")

            enriched["enrichment"]["data_quality"] = {
                "has_before": before is not None,
                "has_after": after is not None,
                "field_count": len(after) if after else 0,
                "is_complete": after is not None and len(after) > 0
            }

            # Add business logic enrichment for customer data
            if after and "email" in after:
                email = after.get("email", "")
                enriched["enrichment"]["customer_insights"] = {
                    "email_domain": email.split("@")[1] if "@" in email else None,
                    "has_email": bool(email),
                    "email_length": len(email)
                }

            # Add message metadata
            enriched["enrichment"]["processing_metadata"] = {
                "function_name": context.get_function_name() if hasattr(context, 'get_function_name') else "cdc-enrichment",
                "function_version": context.get_function_version() if hasattr(context, 'get_function_version') else "1.0",
                "message_id": str(context.get_message_id()) if hasattr(context, 'get_message_id') else None,
                "topic": context.get_current_message_topic_name() if hasattr(context, 'get_current_message_topic_name') else None,
                "partition_id": context.get_partition_id() if hasattr(context, 'get_partition_id') else None
            }

            # Convert to JSON and return
            output = json.dumps(enriched, indent=2)
            context.get_logger().info(f"Enriched message from {source.get('table', 'unknown')} - op: {op}")

            return output.encode('utf-8')

        except Exception as e:
            context.get_logger().error(f"Error processing message: {str(e)}")
            # Return original message on error
            return input_bytes
