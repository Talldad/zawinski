mapping(string:mixed) connections = ([]);

void response_auth(mapping conn, bytes line)
{
	if (has_prefix(line, "OK")) send(conn, "folders list \"\" *\n");
	else send(conn, "quit logout\n");
}

//NOTE: Currently presumes ASCII for everything that matters.
//Binary data may be transmitted at various points (though it *should* be
//MIME-encoded or something), but I'm not going to deal with that yet.
void sockread(mapping conn, bytes data)
{
	conn->readbuffer += data;
	while (sscanf(conn->readbuffer, "%s %s\n%s", ascii msg, bytes line, conn->readbuffer))
	{
		write(">>> %s\n", line);
		if (function resp = conn["response_" + msg] || this["response_" + msg]) resp(conn, line);
	}
}

//Clean up the socket connection; it's assumed to have already been closed.
void sockclosed(mapping conn)
{
	//TODO: Reconnect? Or at least show that the connection's broken.
	werror("DISCONNECTED\n");
	conn->sock=0; //Break refloop
}

//Write as much buffered socket data as possible
void sockwrite(mapping conn)
{
	if (conn->sock && conn->writeme!="") conn->writeme=conn->writeme[conn->sock->write(conn->writeme)..];
}

int send(mapping conn,string text)
{
	if (!conn) return 0;
	if (!conn->sock) return 0; //Discard text if we're not connected - no point keeping it all.
	if (text) conn->writeme += string_to_utf8(text);
	sockwrite(conn);
	return 1;
}

void complete_connection(string|Stdio.File|int(0..0) status, mapping conn)
{
	if (stringp(status)) {werror("%%%%%% %s\n", status); return;}
	object est = m_delete(conn, "establish"); //De-floop. Whatever happens here, it's done and finished. No more resolving.
	if (!status)
	{
		if (!est->errno) werror("%%% Unable to resolve host name.\n");
		else werror("%%%%%% Error connecting to %s: %s [%d]\n", conn->worldname, strerror(est->errno), est->errno);
		return;
	}
	write("CONNECTED\n");
	conn->sock = status;
	conn->sock->set_id(conn); //Refloop
	//Note: In setting the callbacks, use G->G->connection->x instead of just x, in case this is the old callback.
	//Not that that'll be likely - you'd have to "/update connection" while in the middle of establishing one -
	//but it's pretty cheap to do these lookups, and it'd be a nightmare to debug if it were ever wrong.
	conn->sock->set_nonblocking(G->G->connection->sockread, G->G->connection->sockwrite, G->G->connection->sockclosed);
	G->G->connection->sockread(conn, est->data_rcvd);
}

void connect()
{
	object win = G->G->windows->window;
	if (!win) call_out(connect, 0.1); //Shouldn't happen. If we find ourselves racing, somehow, just delay startup a bit.
	mapping lose = connections - persist["accounts"];
	mapping gain = persist["accounts"] - connections;
	foreach (lose; string addr; mapping conn)
	{
		write("Disconnecting from %s\n", addr);
		m_delete(connections, addr);
		if (conn->socket) conn->socket->write("a logout\n");
		//Delete from the TreeStore. Is there a better way to do this??
		object iter = win->folders->get_iter_from_string("0");
		if (!iter) continue; //Shouldn't happen - implies that the tree is empty, ergo we're desynchronized somewhere.
		do
		{
			if (win->folders->get_value(iter, 0) == addr) {win->folders->remove(iter); break;}
		} while (win->folders->iter_next(iter));
	}
	foreach (gain; string addr; mapping info)
	{
		write("Connecting to %s\n", addr);
		mapping conn = connections[addr] = ([
			"readbuffer": "",
			"writeme": sprintf("auth login %s %s\n", info->login, info->password),
		]);
		object root = win->folders->append();
		win->folders->set_row(root, ({addr}));
		win->folders->set_row(win->folders->append(root), ({"INBOX"}));
		win->folderview->expand_all();
		conn->establish = establish_connection(info->imap, 143, complete_connection, conn);
	}
}

void create()
{
	if (G->G->connection) connections = G->G->connection->connections;
	G->G->connection = this;
	call_out(connect, 0);
}
