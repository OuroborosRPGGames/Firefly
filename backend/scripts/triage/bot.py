"""TriageBot orchestrator — coordinates all pipeline stages."""
from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Optional

from .clusterer import cluster_queries


class TriageBot:
    def __init__(self, config, state, api, claude, actions, logger: logging.Logger):
        self.config = config
        self.state = state
        self.api = api
        self.claude = claude
        self.actions = actions
        self.logger = logger

    def run(self, single_ticket_id: Optional[int] = None, autohelp_only: bool = False):
        run_start = datetime.now(timezone.utc).isoformat()
        self.state.prune()

        if not autohelp_only:
            self._process_tickets(single_ticket_id)

        # Autohelp only runs in full mode (no single_ticket_id)
        if single_ticket_id is None:
            self._process_autohelp_gaps(run_start)

        if not self.config.dry_run:
            self.state.update_last_run()
            self.state.save()

    def _process_tickets(self, single_ticket_id: Optional[int]):
        if single_ticket_id is not None:
            tickets = [self.api.get_ticket(single_ticket_id)]
        else:
            all_tickets = self.api.get_open_tickets()
            tickets = [t for t in all_tickets if not self.state.is_processed(t["id"])]

        self.logger.info(f"Processing {len(tickets)} ticket(s)")
        for ticket in tickets:
            self._process_single_ticket(ticket)

    def _process_single_ticket(self, ticket: dict):
        ticket_id = ticket["id"]
        subject = ticket.get("subject", "")
        self.logger.info(f"Investigating ticket #{ticket_id}: {subject[:60]}")

        try:
            helpfiles = self.api.search_helpfiles(subject, limit=5)
            prompt = self.claude.build_ticket_prompt(ticket, helpfiles)
            result = self.claude.run(prompt)
            self.actions.dispatch_ticket_result(ticket_id, subject, result)
        except Exception as e:
            self.logger.error(f"Ticket #{ticket_id}: investigation failed: {e}")
            try:
                self.api.update_ticket_notes(
                    ticket_id, f"[triage_bot] Investigation failed: {str(e)[:200]}"
                )
            except Exception:
                pass
        finally:
            if not self.config.dry_run:
                self.state.mark_processed(ticket_id)

    def _process_autohelp_gaps(self, run_start: str):
        queries = self.api.get_unmatched_autohelp(since=self.state.last_autohelp_cursor)

        if not queries:
            self.logger.info("No unmatched autohelp queries since last run")
            if not self.config.dry_run:
                self.state.update_autohelp_cursor(run_start)
            return

        clusters = cluster_queries(queries)
        large = [c for c in clusters if c["total_count"] >= self.config.min_autohelp_cluster_size]
        self.logger.info(f"Found {len(large)} doc gap cluster(s) to investigate")

        for cluster in large:
            self._process_doc_gap(cluster)

        if not self.config.dry_run:
            self.state.update_autohelp_cursor(run_start)

    def _process_doc_gap(self, cluster: dict):
        rep = cluster["representative"]
        self.logger.info(f"Investigating doc gap: '{rep}' ({cluster['total_count']} queries)")
        try:
            prompt = self.claude.build_docgap_prompt(cluster["queries"], cluster["total_count"])
            result = self.claude.run(prompt)
            self.actions.dispatch_docgap_result(cluster, result)
        except Exception as e:
            self.logger.error(f"Doc gap '{rep}': investigation failed: {e}")
