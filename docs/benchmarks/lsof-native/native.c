#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <sys/resource.h>
#include <arpa/inet.h>
#include <time.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static double cpu(void) { struct rusage r; getrusage(RUSAGE_SELF, &r); return r.ru_utime.tv_sec + r.ru_utime.tv_usec/1e6 + r.ru_stime.tv_sec+r.ru_stime.tv_usec/1e6; }
static const char *states[] = {"CLOSED","LISTEN","SYN_SENT","SYN_RCVD","ESTABLISHED","CLOSE_WAIT","FIN_WAIT_1","CLOSING","LAST_ACK","FIN_WAIT_2","TIME_WAIT","RESERVED"};
int main(void) {
    double start=now(), cstart=cpu();
    int cap=proc_listallpids(NULL,0)+512, *pids=calloc(cap,sizeof(int));
    int n=proc_listallpids(pids,cap*sizeof(int));
    if(n<0 || n>=cap) return 2;
    int denied=0, vanished=0, other=0, fdRead=0, sockets=0, count=0, accessible=0, truncated=0;
    // Output records in-memory before writing to stdout; timings include enumeration/normalization, not stdout IO.
    char *output=NULL; size_t outSize=0; FILE *stream=open_memstream(&output,&outSize);
    for(int i=0;i<n;i++) {
        int pid=pids[i]; if(pid<=0) continue;
        struct proc_bsdinfo bsd={0};
        if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&bsd,sizeof(bsd))!=sizeof(bsd)) {
            if(errno==EPERM || errno==EACCES) denied++; else if(errno==ESRCH) vanished++; else other++;
            continue;
        }
        int size=proc_pidinfo(pid,PROC_PIDLISTFDS,0,NULL,0);
        if(size<=0) { if(errno==EPERM || errno==EACCES) denied++; continue; }
        accessible++;
        int capacity=size+64*sizeof(struct proc_fdinfo), bytes=0;
        struct proc_fdinfo *fds=NULL;
        for(int attempt=0;attempt<5;attempt++) {
            fds=realloc(fds,capacity);
            bytes=proc_pidinfo(pid,PROC_PIDLISTFDS,0,fds,capacity);
            if(bytes<capacity) break;
            capacity*=2;
        }
        if(bytes<0) { free(fds); continue; }
        if(bytes>=capacity) truncated++;
        int nfds=bytes/sizeof(struct proc_fdinfo); fdRead+=nfds;
        for(int j=0;j<nfds;j++) {
            if(fds[j].proc_fdtype!=PROX_FDTYPE_SOCKET) continue;
            struct socket_fdinfo socket={0}; sockets++;
            if(proc_pidfdinfo(pid,fds[j].proc_fd,PROC_PIDFDSOCKETINFO,&socket,sizeof(socket))!=sizeof(socket)) {
                if(errno==EPERM || errno==EACCES) denied++; else if(errno==ESRCH || errno==EBADF) vanished++; else other++;
                continue;
            }
            struct socket_info *s=&socket.psi;
            if(s->soi_family!=AF_INET && s->soi_family!=AF_INET6) continue;
            if(s->soi_protocol!=IPPROTO_TCP && s->soi_protocol!=IPPROTO_UDP) continue;
            int tcp=s->soi_protocol==IPPROTO_TCP;
            if((tcp && s->soi_kind!=SOCKINFO_TCP)||(!tcp && s->soi_kind!=SOCKINFO_IN)) continue;
            struct in_sockinfo *in=tcp?&s->soi_proto.pri_tcp.tcpsi_ini:&s->soi_proto.pri_in;
            char local[INET6_ADDRSTRLEN]={0},remote[INET6_ADDRSTRLEN]={0};
            int af=(s->soi_family==AF_INET || (in->insi_vflag & INI_IPV4))?AF_INET:AF_INET6;
            const void *la=af==AF_INET?(void*)&in->insi_laddr.ina_46.i46a_addr4:(void*)&in->insi_laddr.ina_6;
            const void *ra=af==AF_INET?(void*)&in->insi_faddr.ina_46.i46a_addr4:(void*)&in->insi_faddr.ina_6;
            inet_ntop(af,la,local,sizeof(local)); inet_ntop(af,ra,remote,sizeof(remote));
            int state=tcp?s->soi_proto.pri_tcp.tcpsi_state:-1;
            fprintf(stream,"R\t%d\t%u\t%s\t%d\t%s\t%d\t%s\t%d\t%s\n",pid,fds[j].proc_fd,
                    tcp?"TCP":"UDP",s->soi_family==AF_INET?4:6,local,ntohs((uint16_t)in->insi_lport),
                    remote,ntohs((uint16_t)in->insi_fport),state>=0&&state<12?states[state]:"-");
            count++;
        }
        free(fds);
    }
    fclose(stream); free(pids);
    printf("M\t%.6f\t%.6f\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",(now()-start)*1000,(cpu()-cstart)*1000,n,accessible,fdRead,sockets,count,denied,vanished,other+truncated);
    fwrite(output,1,outSize,stdout); free(output);
    return 0;
}
