import {transitResolved} from "./alpha-work.ts";
import {type PendingTransit} from "./pending-transits.ts";

export function queueReportTransits(
  report: {inFlightToHub: readonly {transitId: string}[]},
  queue: (transitId: string) => void,
) {
  for (const transit of report.inFlightToHub) queue(transit.transitId);
}

export function createKeeperTransitRetry(dependencies: {
  state: (entry: PendingTransit) => Promise<number>;
  acknowledge: (entry: PendingTransit) => Promise<void>;
}) {
  return async (entry: PendingTransit): Promise<boolean> => {
    if (transitResolved(await dependencies.state(entry))) return true;
    await dependencies.acknowledge(entry);
    return transitResolved(await dependencies.state(entry));
  };
}
