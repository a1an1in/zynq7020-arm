APP = s2mm-user
APP_OBJS = s2mm_user.o

all: $(APP)

$(APP): $(APP_OBJS)
	$(CC) $(LDFLAGS) -o $@ $(APP_OBJS) $(LDLIBS)

clean:
	-rm -f $(APP) *.o *.elf *.gdb