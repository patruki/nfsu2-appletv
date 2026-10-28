/* The app's entry point: everything else is in libnfsu2.a (tvos/host/host_tv.m). */
int nfsu2_tv_run(int argc, char **argv);
int main(int argc, char **argv){ return nfsu2_tv_run(argc, argv); }
