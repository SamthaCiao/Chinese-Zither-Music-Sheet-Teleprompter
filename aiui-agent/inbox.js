let pending = null;

export function keepQuery(query) {
  if (query) pending = query;
}

export function takeQuery() {
  const query = pending;
  pending = null;
  return query;
}
