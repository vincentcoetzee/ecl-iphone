/* tcp.c  -- stream interface to TCP					*/

/*
    Copyright (c) 1990, Giuseppe Attardi.
    Copyright (c) 2001, Juan Jose Garcia Ripoll.

    ECL is free software; you can redistribute it and/or modify it
    under the terms of the GNU General Library Public License as published
    by the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    See file '../Copyright' for full details.
*/

#include <stdio.h>
#include <sys/types.h>
#include <errno.h>

#include <netinet/in.h>
#include <netdb.h> 
#include <sys/socket.h>
#include <sys/un.h>
#include <string.h>

#include <sys/ioctl.h>

#include "ecl.h"

/* Maximum length for a unix socket pathname */
#define UNIX_MAX_PATH	107

extern int errno;

/***********************************************************************
 * Client side
 **********************************************************************/

/* 
 * Attempts to connect to server, given host and port. Returns file 
 * descriptor (network socket) or 0 if connection fails.
 */
static
int connect_to_server(char *host, int port)
{
  struct sockaddr_in inaddr;	/* INET socket address. */
  struct sockaddr *addr;	/* address to connect to */
  struct hostent *host_ptr;
  int addrlen;			/* length of address */
  extern char *getenv();
  extern struct hostent *gethostbyname();
  int fd;			/* Network socket */

  /* Get the statistics on the specified host. */
  if ((inaddr.sin_addr.s_addr = inet_addr(host)) == -1) {
    if ((host_ptr = gethostbyname(host)) == NULL) {
      /* No such host! */
      errno = EINVAL;
      return(0);
    }
    /* Check the address type for an internet host. */
    if (host_ptr->h_addrtype != AF_INET) {
      /* Not an Internet host! */
      errno = EPROTOTYPE;
      return(0);
    }
    /* Set up the socket data. */
    inaddr.sin_family = host_ptr->h_addrtype;
    memcpy((char *)&inaddr.sin_addr, (char *)host_ptr->h_addr,
	   sizeof(inaddr.sin_addr));
  } 
  else
    inaddr.sin_family = AF_INET;

  addr = (struct sockaddr *) &inaddr;
  addrlen = sizeof (struct sockaddr_in);
  inaddr.sin_port = port;
  inaddr.sin_port = htons(inaddr.sin_port);
  /*
   * Open the network connection.
   */
  if ((fd = socket((int) addr->sa_family, SOCK_STREAM, 0)) < 0)
    return(0);			/* errno set by system call. */

#ifdef TCP_NODELAY
  /* make sure to turn off TCP coalescence */
  { int mi;
    setsockopt (fd, IPPROTO_TCP, TCP_NODELAY, &mi, sizeof (int));
  }
#endif
#ifdef THREADS
  start_critical_section();
#endif
  if (connect(fd, addr, addrlen) == -1) {
    (void) close (fd);
#ifdef THREADS
    end_critical_section();
#endif
    return(0);		/* errno set by system call. */
  }
  /*
   * Return the id if the connection succeeded.
   */
  return(fd);
}


/***********************************************************************
 * Server side
 **********************************************************************/
/*
 * Creates a server port. Returns file 
 * descriptor (network socket) or 0 if connection fails.
 */

int
create_server_port(int port)
{
  struct sockaddr_in inaddr;	/* INET socket address. */
  struct sockaddr *addr;	/* address to connect to */
  int addrlen;			/* length of address */
  int request, conn;		/* Network socket */

  /*
   * Open the network connection.
   */
  if ((request = socket(AF_INET, SOCK_STREAM, 0)) < 0) {
    return(0);			/* errno set by system call. */
  }

#ifdef SO_REUSEADDR
    /* Necesary to restart the server without a reboot */
    {
	int one = 1;
	setsockopt(request, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(int));
    }
#endif /* SO_REUSEADDR */
#ifdef TCP_NODELAY
  /* make sure to turn off TCP coalescence */
  { int mi;
    setsockopt(request, IPPROTO_TCP, TCP_NODELAY, &mi, sizeof (int));
  }
#endif

  /* Set up the socket data. */
  memset((char *)&inaddr, 0, sizeof(inaddr));
  inaddr.sin_family = AF_INET;
  inaddr.sin_port = htons(port);
  inaddr.sin_addr.s_addr = htonl(INADDR_ANY);

  if (bind(request, (struct sockaddr *)&inaddr, sizeof (inaddr)))
    FEerror("Binding TCP socket", 0);
  if (listen(request, 1))
    FEerror("TCP listening", 0);
#ifdef THREADS
  /* Don't make this file-descriptor non-blocking
   * just block on it before we attempt to accept from it
   * Think _hard_ about moving this out of here, into somewhere sane
   * and creating an 'accepting' stream type, which is bound to a port
   * on reading returns streams
   */
  {
    FILE *fp;			/* need to use FILE *'s rather than fd... *sigh* */
    if ((fp = fdopen(request, "r")) == (FILE *)0)
      printf("fdopen didn't work on accept fd!\n"); fflush(stdout);
    fcntl(request, F_SETFL, O_NONBLOCK);
    clearerr(fp);

  loop:	errno = 0;
    if ((conn = accept(request, (struct sockaddr *)NULL, (int *)NULL)) < 0)
    if (errno) {
      lwpblockon(active, fp, PD_INPUT);
      clearerr(fp);
      goto loop;
    } else {
      fclose(fp);
      FEerror("Accepting requests", 0);
    }
    fclose(fp);
  }
#else
  if ((conn = accept(request, (struct sockaddr *)NULL, (int *)NULL)) < 0)
    FEerror("Accepting requests", 0);
#endif	/* THREADS */

  return(conn);
}

/***********************************************************************
 * Interface from file descriptors to streams
 **********************************************************************/

cl_object
make_stream(cl_object host, int fd, enum smmode smm)
{
   cl_object stream;
   char *mode;			/* file open mode */
   FILE *fp;			/* file pointer */

   switch(smm) {
    case smm_input:
      mode = "r";
      break;
    case smm_output:
      mode = "w";
      break;
    default:
      FEerror("make_stream: wrong mode", 0);
   }
   fp = fdopen(fd, mode);

   stream = cl_alloc_object(t_stream);
   stream->stream.mode = (short)smm;
   stream->stream.file = fp;
   stream->stream.object0 = @'base-char';
   stream->stream.object1 = host; /* not really used */
   stream->stream.int0 = stream->stream.int1 = 0;
#if !defined(GBC_BOEHM)
   fp->_IO_buf_base = NULL; /* BASEFF */; 
   setbuf(fp, stream->stream.buffer = cl_alloc_atomic(BUFSIZ)); 
#endif
   return(stream);
}

/***********************************************************************
 * Public interface to lisp environment
 **********************************************************************/

/* 
   @open-client-stream --

   To test this function, try:
   (setq s (si:open-client-stream "host" 13))
   (read-line s)
   "Wed Jun 22 19:44:36 METDST 1994"
*/
@(defun si::open_client_stream (host port)
   int fd;			/* file descriptor */
   cl_object streamIn, streamOut;
@
   if (type_of(host) != t_string)
     FEwrong_type_argument(@'string', host);

   if (!FIXNUMP(port))
     FEwrong_type_argument(TSpositive_number, port);

   /* FIXME! Why? */
   if (host->string.fillp > BUFSIZ - 1)
     FEerror("~S is a too long file name.", 1, host);

   start_critical_section();
   fd = connect_to_server(host->string.self, fix(port)); 
   end_critical_section();

   if (fd == 0)
     @(return Cnil)

   streamIn = make_stream(host, fd, smm_input);
   streamOut = make_stream(host, fd, smm_output);

   @(return make_two_way_stream(streamIn, streamOut))
@)

@(defun si::open_server_stream (port)
   int fd;			/* file descriptor */
   cl_object streamIn, streamOut;
   cl_object output;
@
   if (!FIXNUMP(port))
     FEwrong_type_argument(TSpositive_number, port);

   start_critical_section();
   fd = create_server_port(fix(port));
   end_critical_section();

   if (fd == 0)
     output = Cnil;
   else {
     streamIn = make_stream(Cnil, fd, smm_input);
     streamOut = make_stream(Cnil, fd, smm_output);
     output = make_two_way_stream(streamIn, streamOut);
   }
   @(return output)
@)

/************************************************************
 * Unix sockets						    *
 ************************************************************/

@(defun si::open-unix-socket-stream (path)
	int fd;			/* file descriptor */
	cl_object streamIn, streamOut;
	struct sockaddr_un addr;
@
	if (type_of(path) != t_string)
		FEwrong_type_argument(@'string', path);
	if (path->string.fillp > UNIX_MAX_PATH-1)
		FEerror("~S is a too long file name.", 1, path);

	fd = socket(PF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		FEfilesystem_error("Unable to create unix socket", 0);
		@(return Cnil)
	}

	memcpy(addr.sun_path, path->string.self, path->string.fillp);
	addr.sun_path[path->string.fillp] = 0;
	addr.sun_family = AF_UNIX;

	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		close(fd);
		FEfilesystem_error("Unable to connect to unix socket ~A", 1, path);
		@(return Cnil)
	}

	streamIn = make_stream(path, fd, smm_input);
	streamOut = make_stream(path, fd, smm_output);

	@(return make_two_way_stream(streamIn, streamOut))
@)

/************************************************************
 * Hostname resolution					    *
 ************************************************************/
@(defun si::lookup-host-entry (host_or_address)
	struct hostent *he;
	unsigned long l;
	cl_object name, aliases, addresses;
	int i;
@
	switch (type_of(host_or_address)) {
	case t_string:
		host_or_address->string.self[host_or_address->string.fillp] = 0;
		he = gethostbyname(host_or_address->string.self);
		break;
	case t_fixnum:
		l = fix(host_or_address);
		he = gethostbyaddr(&l, 4, AF_INET);
		break;
	case t_bignum:
		l = big_to_ulong(host_or_address);
		he = gethostbyaddr(&l, 4, AF_INET);
		break;
	default:
		FEerror("LOOKUP-HOST-ENTRY: Number or string expected, got ~S",
			1, host_or_address);
	}
	if (he == NULL)
		FEerror("LOOKUP-HOST-ENTRY: Failed to find entry for ~S",
			1, host_or_address);
	name = make_string_copy(he->h_name);
	aliases = Cnil;
	for (i = 0; he->h_aliases[i] != 0; i++)
		aliases = CONS(make_string_copy(he->h_aliases[i]), aliases);
	addresses = Cnil;
	for (i = 0; he->h_addr_list[i]; i++) {
		unsigned long *s = (unsigned long*)(he->h_addr_list[i]);
		l = *s;
		addresses = CONS(make_integer(l), addresses);
	}
	@(return name aliases addresses)
@)
