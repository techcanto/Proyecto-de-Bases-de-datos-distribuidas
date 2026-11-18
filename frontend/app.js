/* ═══════════════════════════════════════════════════════════════════════════
   app.js — Lógica principal del frontend distribuido
   ═══════════════════════════════════════════════════════════════════════════ */

const API = "";

/* ── Estado global ──────────────────────────────────────────────────────────── */
let nodoLocal         = null;  // {node_index, host, id_min, id_max, total_nodos}
let clienteActual     = null;  // cliente abierto en modal de detalle
let editandoDireccion = null;  // dirección que se está editando en modal de dir anidada
let tablaActual       = null;  // {nombre, columnas, pk_col} al abrir CRUD dinámico

/* ── Colores de nodo ────────────────────────────────────────────────────────── */
function colorNodo(nodeIndex) {
  const hue = (nodeIndex * 137) % 360;
  return `hsl(${hue}, 55%, 40%)`;
}

function badgeNodo(nodeIndex) {
  const color = colorNodo(nodeIndex);
  return `<span class="node-badge" style="background:${color}">Nodo ${nodeIndex}</span>`;
}

/* ═══════════════════════════════════════════════════════════════════════════
   INICIALIZACIÓN
   ═══════════════════════════════════════════════════════════════════════════ */
async function inicializar() {
  // Navegación entre secciones
  document.querySelectorAll(".nav-link").forEach(link => {
    link.addEventListener("click", e => {
      e.preventDefault();
      const sec = link.dataset.section;
      document.querySelectorAll(".nav-link").forEach(l => l.classList.remove("active"));
      document.querySelectorAll(".section").forEach(s => s.classList.remove("active"));
      link.classList.add("active");
      document.getElementById(`section-${sec}`).classList.add("active");
      if (sec === "tablas")      cargarTablas();
      if (sec === "direcciones") listarTodasDirecciones();
    });
  });

  // Buscar clientes al presionar Enter
  document.getElementById("input-busqueda").addEventListener("keydown", e => {
    if (e.key === "Enter") buscarClientes();
  });

  // Buscar direcciones al presionar Enter
  document.getElementById("input-busqueda-dir").addEventListener("keydown", e => {
    if (e.key === "Enter") buscarDirecciones();
  });

  // Cargar info del nodo local
  try {
    const res  = await fetch(`${API}/api/nodo-info`);
    const json = await res.json();
    nodoLocal  = json.data;
    document.getElementById("badge-nodo").textContent =
      `Nodo ${nodoLocal.node_index} · IDs ${nodoLocal.id_min}–${nodoLocal.id_max}`;
    document.getElementById("badge-nodo").style.borderColor = colorNodo(nodoLocal.node_index);
    document.getElementById("badge-nodo").style.color       = colorNodo(nodoLocal.node_index);
  } catch {
    document.getElementById("badge-nodo").textContent = "Nodo desconocido";
    toast("No se pudo conectar al backend.", "error");
  }

  await listarTodos();
  cargarTailscale().catch(() => {});
}

/* ═══════════════════════════════════════════════════════════════════════════
   CLIENTES — LISTA Y BÚSQUEDA
   ═══════════════════════════════════════════════════════════════════════════ */
async function listarTodos() {
  renderTablaClientes(null, true);
  try {
    const res  = await fetch(`${API}/api/clientes`);
    const json = await res.json();
    renderTablaClientes(json.data || []);
  } catch {
    renderTablaClientes([]);
    toast("Error al cargar clientes.", "error");
  }
}

async function buscarClientes() {
  const q     = document.getElementById("input-busqueda").value.trim();
  const campo = document.getElementById("campo-busqueda").value;
  if (!q) { listarTodos(); return; }

  renderTablaClientes(null, true);
  try {
    const res  = await fetch(`${API}/api/clientes/buscar?q=${encodeURIComponent(q)}&campo=${campo}`);
    const json = await res.json();
    if (json.error) { toast(json.error, "error"); renderTablaClientes([]); return; }
    renderTablaClientes(json.data || []);
  } catch {
    renderTablaClientes([]);
    toast("Error en la búsqueda.", "error");
  }
}

function renderTablaClientes(filas, cargando = false) {
  const tbody = document.getElementById("tbody-clientes");
  if (cargando) {
    tbody.innerHTML = `<tr><td colspan="6" class="empty">Cargando...</td></tr>`;
    return;
  }
  if (!filas || filas.length === 0) {
    tbody.innerHTML = `<tr><td colspan="6" class="empty">Sin resultados.</td></tr>`;
    return;
  }
  tbody.innerHTML = filas.map(c => `
    <tr>
      <td>${c.Id}</td>
      <td>${esc(c.Nombre)} ${esc(c.ApellidoPaterno)} ${esc(c.ApellidoMaterno || "")}</td>
      <td><code>${esc(c.RFC)}</code></td>
      <td>${c.IdDireccion != null ? `<code>#${c.IdDireccion}</code>` : '<span class="muted">—</span>'}</td>
      <td>${badgeNodo(c.node_index)}</td>
      <td>
        <div class="actions">
          <button class="btn btn-sm btn-secondary" onclick="abrirDetalle(${c.Id})">Ver</button>
          <button class="btn btn-sm btn-secondary" onclick="abrirModalEditarCliente(${c.Id})">Editar</button>
          <button class="btn btn-sm btn-danger" onclick="confirmarEliminarCliente(${c.Id})">Eliminar</button>
        </div>
      </td>
    </tr>
  `).join("");
}

/* ═══════════════════════════════════════════════════════════════════════════
   MODAL — CREAR / EDITAR CLIENTE
   ═══════════════════════════════════════════════════════════════════════════ */
function abrirModalCrearCliente() {
  document.getElementById("modal-cliente-titulo").textContent = "Nuevo Cliente";
  document.getElementById("cliente-id").value = "";
  document.getElementById("form-cliente").reset();
  abrirModal("modal-cliente");
}

async function abrirModalEditarCliente(id) {
  try {
    const res  = await fetch(`${API}/api/clientes/${id}`);
    const json = await res.json();
    if (json.error) { toast(json.error, "error"); return; }
    const c = json.data;
    document.getElementById("modal-cliente-titulo").textContent = "Editar Cliente";
    document.getElementById("cliente-id").value       = c.Id;
    document.getElementById("cliente-nombre").value   = c.Nombre;
    document.getElementById("cliente-ap-pat").value   = c.ApellidoPaterno;
    document.getElementById("cliente-ap-mat").value   = c.ApellidoMaterno || "";
    document.getElementById("cliente-rfc").value      = c.RFC;
    document.getElementById("cliente-id-dir").value   = c.IdDireccion != null ? c.IdDireccion : "";
    abrirModal("modal-cliente");
  } catch {
    toast("Error al cargar el cliente.", "error");
  }
}

async function submitCliente(e) {
  e.preventDefault();
  const id    = document.getElementById("cliente-id").value;
  const idDir = document.getElementById("cliente-id-dir").value.trim();
  const body  = {
    Nombre:          document.getElementById("cliente-nombre").value.trim(),
    ApellidoPaterno: document.getElementById("cliente-ap-pat").value.trim(),
    ApellidoMaterno: document.getElementById("cliente-ap-mat").value.trim() || null,
    RFC:             document.getElementById("cliente-rfc").value.trim().toUpperCase(),
    IdDireccion:     idDir !== "" ? parseInt(idDir) : null,
  };

  // Validación mínima: RFC no vacío (cualquier cadena es válida)
  if (!body.RFC) {
    toast("El RFC no puede estar vacío.", "error");
    return;
  }

  try {
    const url    = id ? `${API}/api/clientes/${id}` : `${API}/api/clientes`;
    const method = id ? "PUT" : "POST";
    const res    = await fetch(url, {
      method,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const json = await res.json();
    if (json.error) { toast(json.error, "error"); return; }
    toast(id ? "Cliente actualizado." : "Cliente registrado.", "ok");
    cerrarModal("modal-cliente");
    listarTodos();
  } catch {
    toast("Error de red.", "error");
  }
}

async function confirmarEliminarCliente(id) {
  if (!confirm(`¿Eliminar el cliente #${id} y todas sus direcciones?`)) return;
  try {
    const res  = await fetch(`${API}/api/clientes/${id}`, { method: "DELETE" });
    const json = await res.json();
    if (json.error) { toast(json.error, "error"); return; }
    toast("Cliente eliminado.", "ok");
    listarTodos();
  } catch {
    toast("Error al eliminar.", "error");
  }
}

/* ═══════════════════════════════════════════════════════════════════════════
   MODAL — DETALLE CLIENTE + DIRECCIONES ANIDADAS
   ═══════════════════════════════════════════════════════════════════════════ */
async function abrirDetalle(id) {
  try {
    const res  = await fetch(`${API}/api/clientes/${id}`);
    const json = await res.json();
    if (json.error) { toast(json.error, "error"); return; }
    clienteActual = json.data;
  } catch {
    toast("Error al cargar el cliente.", "error");
    return;
  }

  const c = clienteActual;
  document.getElementById("modal-detalle-titulo").textContent =
    `${c.Nombre} ${c.ApellidoPaterno} ${c.ApellidoMaterno || ""}`;

  document.getElementById("detalle-info").innerHTML = `
    <div><strong>ID</strong>${c.Id}</div>
    <div><strong>RFC</strong>${esc(c.RFC)}</div>
    <div><strong>Dirección asociada</strong>${c.IdDireccion != null ? `#${c.IdDireccion}` : '—'}</div>
    <div><strong>Nodo</strong>${badgeNodo(c.node_index)}</div>
  `;

  const esLocal = nodoLocal && c.node_index === nodoLocal.node_index;
  const btnNuevaDir = document.getElementById("btn-nueva-dir");
  btnNuevaDir.style.display = esLocal ? "" : "none";
  if (!esLocal) btnNuevaDir.title = "Solo la sucursal propietaria puede agregar direcciones.";

  abrirModal("modal-detalle");
  cargarDirecciones(c.Id);
}

async function cargarDirecciones(clienteId) {
  const contenedor = document.getElementById("lista-direcciones");
  contenedor.innerHTML = `<p class="empty" style="padding:1rem 1.25rem">Cargando...</p>`;
  try {
    const res  = await fetch(`${API}/api/clientes/${clienteId}/direcciones`);
    const json = await res.json();
    if (json.error) { contenedor.innerHTML = `<p class="empty">Error: ${json.error}</p>`; return; }
    const dirs = json.data || [];
    if (dirs.length === 0) {
      contenedor.innerHTML = `<p class="empty" style="padding:1rem 1.25rem">Sin direcciones registradas.</p>`;
      return;
    }
    contenedor.innerHTML = dirs.map(d => `
      <div class="dir-card">
        <div class="dir-card-text">
          ${esc(d.Calle)} ${esc(d.Numero)}, ${esc(d.Colonia)}<br>
          ${esc(d.Estado)} — CP ${esc(d.CP)}
        </div>
        <div class="dir-card-actions">
          <button class="btn btn-sm btn-secondary"
            onclick="abrirModalEditarDireccion(${d.Id},${clienteActual.Id})">Editar</button>
          <button class="btn btn-sm btn-danger"
            onclick="confirmarEliminarDireccion(${d.Id},${clienteActual.Id})">Eliminar</button>
        </div>
      </div>
    `).join("");
  } catch {
    contenedor.innerHTML = `<p class="empty">Error de red.</p>`;
  }
}

/* ═══════════════════════════════════════════════════════════════════════════
   MODAL — CREAR / EDITAR DIRECCIÓN (anidada en detalle de cliente)
   ═══════════════════════════════════════════════════════════════════════════ */
function abrirModalCrearDireccion() {
  editandoDireccion = null;
  document.getElementById("modal-dir-titulo").textContent = "Nueva Dirección";
  document.getElementById("dir-id").value        = "";
  document.getElementById("dir-cliente-id").value = clienteActual.Id;
  document.getElementById("form-direccion").reset();
  abrirModal("modal-direccion");
}

async function abrirModalEditarDireccion(dirId, clienteId) {
  try {
    const res  = await fetch(`${API}/api/clientes/${clienteId}/direcciones`);
    const json = await res.json();
    const dir  = (json.data || []).find(d => d.Id === dirId);
    if (!dir) { toast("Dirección no encontrada.", "error"); return; }
    editandoDireccion = dir;
    document.getElementById("modal-dir-titulo").textContent = "Editar Dirección";
    document.getElementById("dir-id").value        = dir.Id;
    document.getElementById("dir-cliente-id").value = clienteId;
    document.getElementById("dir-calle").value    = dir.Calle;
    document.getElementById("dir-numero").value   = dir.Numero;
    document.getElementById("dir-colonia").value  = dir.Colonia;
    document.getElementById("dir-estado").value   = dir.Estado;
    document.getElementById("dir-cp").value       = dir.CP;
    abrirModal("modal-direccion");
  } catch {
    toast("Error al cargar la dirección.", "error");
  }
}

async function submitDireccion(e) {
  e.preventDefault();
  const dirId     = document.getElementById("dir-id").value;
  const clienteId = document.getElementById("dir-cliente-id").value;
  const body = {
    IdCliente: parseInt(clienteId),
    Calle:   document.getElementById("dir-calle").value.trim(),
    Numero:  document.getElementById("dir-numero").value.trim(),
    Colonia: document.getElementById("dir-colonia").value.trim(),
    Estado:  document.getElementById("dir-estado").value.trim(),
    CP:      document.getElementById("dir-cp").value.trim(),
  };

  try {
    let res;
    if (dirId) {
      res = await fetch(`${API}/api/direcciones/${dirId}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
    } else {
      res = await fetch(`${API}/api/clientes/${clienteId}/direcciones`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
    }
    const json = await res.json();
    if (json.error) { toast(json.error, "error"); return; }
    toast(dirId ? "Dirección actualizada." : "Dirección registrada.", "ok");
    cerrarModal("modal-direccion");
    cargarDirecciones(clienteId);
  } catch {
    toast("Error de red.", "error");
  }
}

async function confirmarEliminarDireccion(dirId, clienteId) {
  if (!confirm(`¿Eliminar la dirección #${dirId}?`)) return;
  try {
    const res  = await fetch(`${API}/api/direcciones/${dirId}`, {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ IdCliente: clienteId }),
    });
    const json = await res.json();
    if (json.error) { toast(json.error, "error"); return; }
    toast("Dirección eliminada.", "ok");
    cargarDirecciones(clienteId);
  } catch {
    toast("Error al eliminar.", "error");
  }
}

/* ═══════════════════════════════════════════════════════════════════════════
   SECCIÓN DIRECCIONES — CRUD INDEPENDIENTE
   ═══════════════════════════════════════════════════════════════════════════ */
async function listarTodasDirecciones() {
  renderTablaDirecciones(null, true);
  try {
    const res  = await fetch(`${API}/api/direcciones`);
    const json = await res.json();
    renderTablaDirecciones(json.data || []);
  } catch {
    renderTablaDirecciones([]);
    toast("Error al cargar direcciones.", "error");
  }
}

async function buscarDirecciones() {
  const q     = document.getElementById("input-busqueda-dir").value.trim();
  const campo = document.getElementById("campo-busqueda-dir").value;
  if (!q) { listarTodasDirecciones(); return; }

  renderTablaDirecciones(null, true);
  try {
    const res  = await fetch(`${API}/api/direcciones/buscar?q=${encodeURIComponent(q)}&campo=${campo}`);
    const json = await res.json();
    if (json.error) { toast(json.error, "error"); renderTablaDirecciones([]); return; }
    renderTablaDirecciones(json.data || []);
  } catch {
    renderTablaDirecciones([]);
    toast("Error en la búsqueda.", "error");
  }
}

function renderTablaDirecciones(filas, cargando = false) {
  const tbody = document.getElementById("tbody-direcciones");
  if (cargando) {
    tbody.innerHTML = `<tr><td colspan="8" class="empty">Cargando...</td></tr>`;
    return;
  }
  if (!filas || filas.length === 0) {
    tbody.innerHTML = `<tr><td colspan="8" class="empty">Sin resultados.</td></tr>`;
    return;
  }
  tbody.innerHTML = filas.map(d => `
    <tr>
      <td>${d.Id}</td>
      <td>${esc(d.Calle)} ${esc(d.Numero)}</td>
      <td>${esc(d.Colonia)}</td>
      <td>${esc(d.Estado)}</td>
      <td><code>${esc(d.CP)}</code></td>
      <td>${d.IdCliente != null ? `<code>#${d.IdCliente}</code>` : '<span class="muted">—</span>'}</td>
      <td>${badgeNodo(d.node_index)}</td>
      <td>
        <div class="actions">
          <button class="btn btn-sm btn-secondary" onclick="abrirModalEditarDireccionIndep(${d.Id})">Editar</button>
          <button class="btn btn-sm btn-danger" onclick="confirmarEliminarDireccionIndep(${d.Id})">Eliminar</button>
        </div>
      </td>
    </tr>
  `).join("");
}

function abrirModalCrearDireccionIndep() {
  document.getElementById("modal-dir-indep-titulo").textContent = "Nueva Dirección";
  document.getElementById("dir-indep-id").value         = "";
  document.getElementById("dir-indep-cliente-id").value = "";
  document.getElementById("form-direccion-indep").reset();
  abrirModal("modal-direccion-indep");
}

async function abrirModalEditarDireccionIndep(dirId) {
  try {
    const res  = await fetch(`${API}/api/direcciones/${dirId}`);
    const json = await res.json();
    if (json.error) { toast(json.error, "error"); return; }
    const d = json.data;
    document.getElementById("modal-dir-indep-titulo").textContent = "Editar Dirección";
    document.getElementById("dir-indep-id").value         = d.Id;
    document.getElementById("dir-indep-cliente-id").value = d.IdCliente != null ? d.IdCliente : "";
    document.getElementById("dir-indep-calle").value      = d.Calle;
    document.getElementById("dir-indep-numero").value     = d.Numero;
    document.getElementById("dir-indep-colonia").value    = d.Colonia;
    document.getElementById("dir-indep-estado").value     = d.Estado;
    document.getElementById("dir-indep-cp").value         = d.CP;
    abrirModal("modal-direccion-indep");
  } catch {
    toast("Error al cargar la dirección.", "error");
  }
}

async function submitDireccionIndep(e) {
  e.preventDefault();
  const dirId     = document.getElementById("dir-indep-id").value;
  const clienteId = document.getElementById("dir-indep-cliente-id").value.trim();
  const body = {
    Calle:   document.getElementById("dir-indep-calle").value.trim(),
    Numero:  document.getElementById("dir-indep-numero").value.trim(),
    Colonia: document.getElementById("dir-indep-colonia").value.trim(),
    Estado:  document.getElementById("dir-indep-estado").value.trim(),
    CP:      document.getElementById("dir-indep-cp").value.trim(),
  };
  if (clienteId !== "") body.IdCliente = parseInt(clienteId);

  try {
    let res;
    if (dirId) {
      res = await fetch(`${API}/api/direcciones/${dirId}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
    } else {
      res = await fetch(`${API}/api/direcciones`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
    }
    const json = await res.json();
    if (json.error) { toast(json.error, "error"); return; }
    toast(dirId ? "Dirección actualizada." : "Dirección registrada.", "ok");
    cerrarModal("modal-direccion-indep");
    listarTodasDirecciones();
  } catch {
    toast("Error de red.", "error");
  }
}

async function confirmarEliminarDireccionIndep(dirId) {
  if (!confirm(`¿Eliminar la dirección #${dirId}?`)) return;
  try {
    const res  = await fetch(`${API}/api/direcciones/${dirId}`, { method: "DELETE" });
    const json = await res.json();
    if (json.error) { toast(json.error, "error"); return; }
    toast("Dirección eliminada.", "ok");
    listarTodasDirecciones();
  } catch {
    toast("Error al eliminar.", "error");
  }
}

/* ═══════════════════════════════════════════════════════════════════════════
   TABLAS DISTRIBUIDAS
   ═══════════════════════════════════════════════════════════════════════════ */
async function cargarTablas() {
  const contenedor = document.getElementById("lista-tablas");
  contenedor.innerHTML = `<p class="empty">Cargando...</p>`;
  try {
    const res  = await fetch(`${API}/api/tablas`);
    const json = await res.json();
    if (json.error) { contenedor.innerHTML = `<p class="empty">Error: ${json.error}</p>`; return; }
    const tablas = json.data || [];
    if (tablas.length === 0) {
      contenedor.innerHTML = `<p class="empty">No hay tablas registradas.</p>`;
      return;
    }
    contenedor.innerHTML = tablas.map(t => `
      <div class="tabla-card">
        <span>${esc(t)}</span>
        <div class="tabla-card-actions">
          <button class="btn btn-sm btn-secondary" onclick="abrirCrudTabla('${esc(t)}')">CRUD</button>
          <button class="btn btn-sm btn-danger" onclick="confirmarEliminarTabla('${esc(t)}')">Eliminar</button>
        </div>
      </div>
    `).join("");
  } catch {
    contenedor.innerHTML = `<p class="empty">Error de red.</p>`;
  }
}

function abrirModalCrearTabla() {
  document.getElementById("form-tabla").reset();
  document.getElementById("columnas-container").innerHTML = "";
  agregarColumna();
  abrirModal("modal-tabla");
}

function agregarColumna() {
  const container = document.getElementById("columnas-container");
  if (container.children.length === 0) {
    const header = document.createElement("div");
    header.className = "col-header";
    header.innerHTML = `<span>Nombre</span><span>Tipo</span><span>Long.</span><span>NOT NULL</span><span>PK</span><span></span>`;
    container.appendChild(header);
  }
  const fila = document.createElement("div");
  fila.className = "columna-row";
  fila.innerHTML = `
    <input type="text" placeholder="nombre_col" required pattern="[a-zA-Z_][a-zA-Z0-9_]*" class="col-nombre" />
    <select class="col-tipo">
      <option>VARCHAR</option>
      <option>INT</option>
      <option>BIGINT</option>
      <option>DECIMAL</option>
      <option>DATE</option>
      <option>BOOLEAN</option>
      <option>TEXT</option>
      <option>CHAR</option>
    </select>
    <input type="text" placeholder="255" class="col-longitud" />
    <label><input type="checkbox" class="col-notnull" /></label>
    <label><input type="checkbox" class="col-pk" /></label>
    <button type="button" class="btn-remove" onclick="this.closest('.columna-row').remove()">✕</button>
  `;
  container.appendChild(fila);
}

async function submitTabla(e) {
  e.preventDefault();
  const nombre = document.getElementById("tabla-nombre").value.trim();
  const filas  = document.querySelectorAll("#columnas-container .columna-row");

  const columnas = Array.from(filas).map(fila => ({
    nombre:      fila.querySelector(".col-nombre").value.trim(),
    tipo:        fila.querySelector(".col-tipo").value,
    longitud:    fila.querySelector(".col-longitud").value.trim() || null,
    not_null:    fila.querySelector(".col-notnull").checked,
    primary_key: fila.querySelector(".col-pk").checked,
  }));

  if (columnas.length === 0) { toast("Agrega al menos una columna.", "error"); return; }

  try {
    const res  = await fetch(`${API}/api/tablas`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ nombre, columnas }),
    });
    const json = await res.json();
    if (json.error) { toast(json.error, "error"); return; }

    const nodos   = json.data.nodos || [];
    const errores = nodos.filter(n => n.error);
    if (errores.length > 0) {
      errores.forEach(n => toast(`Nodo ${n.node_index}: ${n.error}`, "error"));
    } else {
      toast(`Tabla '${nombre}' creada en ${nodos.length} nodo(s).`, "ok");
    }
    cerrarModal("modal-tabla");
    cargarTablas();
  } catch {
    toast("Error de red.", "error");
  }
}

async function confirmarEliminarTabla(nombre) {
  if (!confirm(`¿Eliminar la tabla '${nombre}' en TODOS los nodos? Esta acción no se puede deshacer.`)) return;
  try {
    const res  = await fetch(`${API}/api/tablas/${encodeURIComponent(nombre)}`, { method: "DELETE" });
    const json = await res.json();
    if (json.error) { toast(json.error, "error"); return; }
    toast(`Tabla '${nombre}' eliminada.`, "ok");
    // Si el CRUD de esta tabla está abierto, cerrar y volver
    if (tablaActual && tablaActual.nombre === nombre) {
      document.getElementById("section-crud-tabla").classList.remove("active");
      document.getElementById("section-tablas").classList.add("active");
      tablaActual = null;
    }
    cargarTablas();
  } catch {
    toast("Error al eliminar la tabla.", "error");
  }
}

/* ═══════════════════════════════════════════════════════════════════════════
   CRUD DINÁMICO DE TABLAS
   ═══════════════════════════════════════════════════════════════════════════ */
async function abrirCrudTabla(nombre) {
  // Obtener estructura de la tabla
  try {
    const res  = await fetch(`${API}/api/tablas/${encodeURIComponent(nombre)}/estructura`);
    const json = await res.json();
    if (json.error) { toast(json.error, "error"); return; }
    const columnas = json.data || [];
    const pk_col   = columnas.find(c => c.COLUMN_KEY === "PRI");

    tablaActual = {
      nombre,
      columnas,
      pk_col: pk_col ? pk_col.COLUMN_NAME : null,
    };
  } catch {
    toast("Error al obtener estructura de la tabla.", "error");
    return;
  }

  // Mostrar sección de CRUD
  document.querySelectorAll(".nav-link").forEach(l => l.classList.remove("active"));
  document.querySelectorAll(".section").forEach(s => s.classList.remove("active"));
  document.getElementById("section-crud-tabla").classList.add("active");

  document.getElementById("crud-tabla-titulo").textContent = `Tabla: ${nombre}`;
  document.getElementById("crud-tabla-pk-info").textContent =
    tablaActual.pk_col
      ? `PK: ${tablaActual.pk_col}`
      : "Sin PK definida — solo lectura y escritura disponibles.";

  await cargarRegistrosTabla();
}

function volverATablas() {
  document.getElementById("section-crud-tabla").classList.remove("active");
  document.getElementById("section-tablas").classList.add("active");
  document.querySelectorAll(".nav-link").forEach(l => {
    if (l.dataset.section === "tablas") l.classList.add("active");
  });
  tablaActual = null;
  cargarTablas();
}

async function cargarRegistrosTabla() {
  if (!tablaActual) return;
  const contenedor = document.getElementById("tabla-dinamica-wrapper");
  contenedor.innerHTML = `<p class="empty">Cargando...</p>`;

  try {
    const res  = await fetch(`${API}/api/tablas/${encodeURIComponent(tablaActual.nombre)}/registros`);
    const json = await res.json();
    if (json.error) { contenedor.innerHTML = `<p class="empty">Error: ${json.error}</p>`; return; }
    const filas = json.data || [];
    renderTablaDinamica(filas, tablaActual.columnas, tablaActual.pk_col);
  } catch {
    contenedor.innerHTML = `<p class="empty">Error de red.</p>`;
  }
}

function renderTablaDinamica(filas, columnas, pk_col) {
  const contenedor = document.getElementById("tabla-dinamica-wrapper");
  const cols        = columnas.map(c => c.COLUMN_NAME);

  let html = `<table class="data-table"><thead><tr>`;
  cols.forEach(c => { html += `<th>${esc(c)}</th>`; });
  html += `<th>Nodo</th><th>Acciones</th></tr></thead><tbody>`;

  if (filas.length === 0) {
    html += `<tr><td colspan="${cols.length + 2}" class="empty">Sin registros.</td></tr>`;
  } else {
    filas.forEach(fila => {
      html += `<tr>`;
      cols.forEach(c => {
        const val = fila[c];
        html += `<td>${val != null ? esc(String(val)) : '<span class="muted">NULL</span>'}</td>`;
      });
      html += `<td>${badgeNodo(fila.node_index)}</td>`;
      if (pk_col) {
        const pk_val = fila[pk_col];
        html += `<td><div class="actions">
          <button class="btn btn-sm btn-secondary" onclick="abrirModalEditarRegistro('${esc(String(pk_val))}')">Editar</button>
          <button class="btn btn-sm btn-danger" onclick="confirmarEliminarRegistro('${esc(String(pk_val))}')">Eliminar</button>
        </div></td>`;
      } else {
        html += `<td><span class="muted">Sin PK</span></td>`;
      }
      html += `</tr>`;
    });
  }
  html += `</tbody></table>`;
  contenedor.innerHTML = html;
}

function abrirModalCrearRegistro() {
  if (!tablaActual) return;
  document.getElementById("modal-registro-titulo").textContent = "Nuevo Registro";
  document.getElementById("registro-pk-valor").value = "";
  renderFormRegistro(null);
  abrirModal("modal-registro");
}

async function abrirModalEditarRegistro(pkValor) {
  if (!tablaActual) return;
  try {
    const res  = await fetch(`${API}/api/tablas/${encodeURIComponent(tablaActual.nombre)}/registros/${encodeURIComponent(pkValor)}`);
    const json = await res.json();
    if (json.error) { toast(json.error, "error"); return; }
    document.getElementById("modal-registro-titulo").textContent = "Editar Registro";
    document.getElementById("registro-pk-valor").value = pkValor;
    renderFormRegistro(json.data);
    abrirModal("modal-registro");
  } catch {
    toast("Error al cargar el registro.", "error");
  }
}

function renderFormRegistro(datos) {
  const contenedor = document.getElementById("form-registro-campos");
  const pk_col     = tablaActual.pk_col;
  contenedor.innerHTML = "";

  tablaActual.columnas.forEach(col => {
    const nombre    = col.COLUMN_NAME;
    const es_pk     = nombre === pk_col;
    const valor     = datos ? (datos[nombre] != null ? datos[nombre] : "") : "";
    const div       = document.createElement("div");
    div.className   = "form-group";
    div.innerHTML   = `
      <label>${esc(nombre)}${es_pk ? ' <span class="badge-pk">PK</span>' : ''}</label>
      <input type="text" id="campo-registro-${esc(nombre)}"
             value="${esc(String(valor))}"
             ${es_pk && datos ? 'readonly style="background:var(--surface);color:var(--muted)"' : ''}
             placeholder="${es_pk ? 'Auto (si es AUTO_INCREMENT)' : nombre}" />
    `;
    contenedor.appendChild(div);
  });
}

async function submitRegistro(e) {
  e.preventDefault();
  if (!tablaActual) return;

  const pk_val    = document.getElementById("registro-pk-valor").value;
  const es_editar = pk_val !== "";
  const datos     = {};

  tablaActual.columnas.forEach(col => {
    const nombre = col.COLUMN_NAME;
    const input  = document.getElementById(`campo-registro-${nombre}`);
    if (!input) return;
    const val    = input.value.trim();
    // En edición, no incluir la PK como campo a actualizar
    if (es_editar && nombre === tablaActual.pk_col) return;
    if (val !== "") datos[nombre] = val;
  });

  if (Object.keys(datos).length === 0) {
    toast("Completa al menos un campo.", "error");
    return;
  }

  try {
    let res;
    if (es_editar) {
      res = await fetch(
        `${API}/api/tablas/${encodeURIComponent(tablaActual.nombre)}/registros/${encodeURIComponent(pk_val)}`,
        { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(datos) }
      );
    } else {
      res = await fetch(
        `${API}/api/tablas/${encodeURIComponent(tablaActual.nombre)}/registros`,
        { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(datos) }
      );
    }
    const json = await res.json();
    if (json.error) { toast(json.error, "error"); return; }
    toast(es_editar ? "Registro actualizado." : "Registro insertado.", "ok");
    cerrarModal("modal-registro");
    cargarRegistrosTabla();
  } catch {
    toast("Error de red.", "error");
  }
}

async function confirmarEliminarRegistro(pkValor) {
  if (!tablaActual) return;
  if (!confirm(`¿Eliminar el registro con ${tablaActual.pk_col} = '${pkValor}'?`)) return;
  try {
    const res  = await fetch(
      `${API}/api/tablas/${encodeURIComponent(tablaActual.nombre)}/registros/${encodeURIComponent(pkValor)}`,
      { method: "DELETE" }
    );
    const json = await res.json();
    if (json.error) { toast(json.error, "error"); return; }
    toast("Registro eliminado.", "ok");
    cargarRegistrosTabla();
  } catch {
    toast("Error al eliminar.", "error");
  }
}

/* ═══════════════════════════════════════════════════════════════════════════
   UTILIDADES
   ═══════════════════════════════════════════════════════════════════════════ */

/** Escapa HTML para prevenir XSS */
function esc(str) {
  if (str == null) return "";
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Abre un modal */
function abrirModal(id) {
  document.getElementById(id).classList.remove("hidden");
}

/** Cierra un modal */
function cerrarModal(id) {
  document.getElementById(id).classList.add("hidden");
}

/** Cierra modales al hacer click en el overlay */
document.addEventListener("click", e => {
  if (e.target.classList.contains("modal-overlay")) {
    e.target.classList.add("hidden");
  }
});

/** Toast de notificación */
function toast(msg, tipo = "ok") {
  const container = document.getElementById("toast-container");
  const el = document.createElement("div");
  el.className  = `toast ${tipo}`;
  el.textContent = msg;
  container.appendChild(el);
  setTimeout(() => el.remove(), 3500);
}

/* ═══════════════════════════════════════════════════════════════════════════
   TAILSCALE — Conectividad
   ═══════════════════════════════════════════════════════════════════════════ */
async function cargarTailscale() {
  const modalOpen = !document.getElementById("modal-tailscale").classList.contains("hidden");
  if (modalOpen) {
    document.getElementById("ts-modal-body").innerHTML = '<p class="empty">Consultando estado...</p>';
  }
  let data;
  try {
    const res  = await fetch(`${API}/api/tailscale`);
    const json = await res.json();
    if (json.error) throw new Error(json.error);
    data = json.data;
  } catch (err) {
    if (modalOpen) {
      document.getElementById("ts-modal-body").innerHTML =
        `<p class="empty" style="color:var(--danger)">Error: ${esc(String(err))}</p>`;
    }
    actualizarBotonTailscale("error");
    return;
  }

  if (modalOpen) renderTailscaleModal(data);
  const allOnline = data.nodes.every(n => n.online);
  const anyOnline = data.nodes.some(n => n.online);
  if (!data.available || !data.running) {
    actualizarBotonTailscale("error");
  } else if (allOnline) {
    actualizarBotonTailscale("ok");
  } else if (anyOnline) {
    actualizarBotonTailscale("partial");
  } else {
    actualizarBotonTailscale("error");
  }
}

function actualizarBotonTailscale(estado) {
  const dot = document.getElementById("ts-dot");
  dot.className = `ts-dot ts-dot--${estado}`;
  const etiquetas = { ok: "Conectado", partial: "Parcial", error: "Desconectado", unknown: "Tailscale" };
  document.getElementById("ts-label").textContent = etiquetas[estado] || "Tailscale";
}

function renderTailscaleModal(data) {
  const body = document.getElementById("ts-modal-body");
  if (!data.available) {
    body.innerHTML = `<p class="empty" style="color:var(--danger)">Tailscale no está instalado en este servidor.</p>`;
    return;
  }
  if (!data.running) {
    body.innerHTML = `<p class="empty" style="color:var(--danger)">Tailscale está instalado pero no está activo.<br>Ejecuta <code>tailscale up</code> para conectarte.</p>`;
    return;
  }

  let html = `<p class="ts-section-title">Esta máquina</p>`;
  html += `<div class="ts-info-row"><span>IP Tailscale</span><code>${esc(data.self_ip || "—")}</code></div>`;
  html += `<div class="ts-info-row"><span>Estado</span><span style="color:var(--success);font-weight:600">● Activo</span></div>`;
  html += `<p class="ts-section-title" style="margin-top:1rem">Nodos del sistema</p>`;

  for (const nodo of data.nodes) {
    const esMismo = nodo.host === data.self_ip;
    let dotCls, badgeCls, badgeTxt;
    if (esMismo) {
      dotCls = "ts-node-dot--self"; badgeCls = "ts-node-badge--self"; badgeTxt = "Esta máquina";
    } else if (nodo.online) {
      dotCls = "ts-node-dot--online"; badgeCls = "ts-node-badge--online"; badgeTxt = "En línea";
    } else {
      dotCls = "ts-node-dot--offline"; badgeCls = "ts-node-badge--offline"; badgeTxt = "Desconectado";
    }
    html += `
      <div class="ts-node-row">
        <span class="ts-node-dot ${dotCls}"></span>
        <span class="ts-node-name">${esc(nodo.hostname || `Nodo ${nodo.index}`)}</span>
        <span class="ts-node-badge ${badgeCls}">${badgeTxt}</span>
        <span class="ts-node-host">${esc(nodo.host)}</span>
      </div>`;
  }

  if (data.peers && data.peers.length > 0) {
    html += `<p class="ts-section-title" style="margin-top:1rem">Todos los peers Tailscale</p>`;
    for (const p of data.peers) {
      html += `
        <div class="ts-node-row">
          <span class="ts-node-dot ${p.online ? "ts-node-dot--online" : "ts-node-dot--offline"}"></span>
          <span class="ts-node-name">${esc(p.hostname || "—")}</span>
          <span class="ts-node-badge ${p.online ? "ts-node-badge--online" : "ts-node-badge--offline"}">${p.online ? "En línea" : "Desconectado"}</span>
          <span class="ts-node-host">${esc((p.ips || [])[0] || "—")}</span>
        </div>`;
    }
  }

  body.innerHTML = html;
}

async function abrirModalTailscale() {
  abrirModal("modal-tailscale");
  await cargarTailscale();
}

/* ─── Arrancar ──────────────────────────────────────────────────────────────── */
document.addEventListener("DOMContentLoaded", inicializar);
