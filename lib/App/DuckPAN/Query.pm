package App::DuckPAN::Query;
# ABSTRACT: Main application/loop for duckpan query

use Moo;
use Data::Printer;
use App::DuckPAN;
use POE qw( Wheel::ReadLine Wheel::Run Filter::Reference );
use Try::Tiny;
use Filesys::Notify::Simple;
use File::Find::Rule;
use Data::Dumper;

use constant ALIAS => '_ADQ_';
use constant CHILDREN => qw(QueryRunner FileMonitor);

# Entry into the module.
sub run {
    my ( $self, $app, $duckpan_args ) = @_;

    select(STDOUT);$|=1;

    # Main session. All events declared have equivalent subs.
    POE::Session->create(
        package_states => [
            $self => [qw(_start _get_user_input _got_user_input _run_query _check_children _create_wheel _fs_monitor _child_signaled _reload_ias _close _print_child_out debug _default)]
        ],
        args => [$app, $duckpan_args]
    );
    POE::Kernel->run();

    return 0;
}

# Initialize the main session. Called once by default.
sub _start {
    my ($k, $h, $app, $args) = @_[KERNEL, HEAP, ARG0, ARG1];

    $k->alias_set(ALIAS);
    my $history_path = $app->cfg->cache_path->child('query_history');

    # Session that handles user input
    my $powh_readline = POE::Wheel::ReadLine->new(
        InputEvent => '_got_user_input'
    );
    $powh_readline->bind_key("C-\\", "interrupt");
    $powh_readline->read_history($history_path);
    $powh_readline->put('(Empty query for ending test)');

    # Store in the heap for use in other events
    @$h{qw(app args console history_path)} = ($app, $args, $powh_readline, $history_path);
    $k->call(ALIAS, '_check_children');

    # Queue user input event
    $k->yield('_get_user_input');
}

# Catches any unhandled events and tells us about them
sub _default { warn "Unhandled event - $_[ARG0]\n" }

# Event to handle user input, triggered by ReadLine
sub _got_user_input {
    my ($k, $h, $input, $exception) = @_[KERNEL, HEAP, ARG0, ARG1];

    if($input){
        my ($console, $history_path) = @$h{qw(console history_path)};

        $console->put("  You entered: $input");
        $console->addhistory($input);
        $console->write_history($history_path);
        # make sure our child QueryRunner exists
        $k->call(ALIAS, '_check_children');
        # Write a request to the QueryRunner to run the query
        $h->{wheels}{$h->{QueryRunner}}->put([$input]);
    }
    else{
        # Exit the program
        $h->{console}->put('\\_o< Thanks for testing!');
        # Explicit exit since we have called alias() which will keep the
        # session alive with no events
        exit 0;
    }
}

# Event that prints the prompt and waits for input.
sub _get_user_input {
    $_[HEAP]{console}->get('Query: ');
}

# Event to check that child wheels exist
sub _check_children {
    my ($k, $h) = @_[KERNEL, HEAP];

    for my $c (CHILDREN){
        unless(exists $h->{$c}){
            # Create new wheel immediately, return here
            my $err = $k->call(ALIAS, _create_wheel => $c);
            if($err){
                $h->{console}->put("Failed to create $c subprocess: $err");
                exit;
            }
        }        
    }
}

# Forks off new wheels
sub _create_wheel {
    my ($k, $h, $type) = @_[KERNEL, HEAP, ARG0];

    return "Wheel already exists" if exists $h->{$type};
    my ($app, $duckpan_args) = @$h{qw(app args)};
    
    # Two wheels types:
    # QueryRunner - executes queries
    # FileMonitor - Watches the file hierarchy for updates
    my ($cmd, $args, $outevent) = $type eq 'QueryRunner' ?
        (\&_run_query, [$duckpan_args], '_print_child_out') :
        (\&_fs_monitor, [$app->get_ia_type()->{dir}], '_reload_ias');

    # Spawn off a new wheel. Usually you would want to use StdioFilter
    # for both in/out communication.  However, some of the DDG code prints
    # warnings to STDOUT which cannot be properly filtered by POE to be
    # passed back to the parent.  So we just print from within the child
    # and pass all output back to the parent via Filter::Line
    my $wheel = POE::Wheel::Run->new(
            Program => $cmd,
            ProgramArgs => $args, 
            CloseOnCall => 1, 
            NoSetSid    => 1,
            StdoutEvent => $outevent,
            StderrEvent => '_print_child_out',
            CloseEvent => '_close',            
            StdinFilter => POE::Filter::Reference->new,
            StdoutFilter => POE::Filter::Line->new(),
            StderrFilter => POE::Filter::Line->new() 
    );
    
    # register child signal handler
    $k->sig_child($wheel->PID, '_child_signaled');
    my $id = $wheel->ID;    
    # store the wheel in the HEAP
    $h->{wheels}{$id} = $wheel;
    # add the type to the HEAP so we know it's created
    $h->{$type} = $id;
    return 0; 
}

# Child signal handler. Prevent further propagation
sub _child_signaled { $_[KERNEL]->sig_handled }

# Output event of FileMonitor child.
sub _reload_ias {
    my ($h, $out) = @_[HEAP, ARG0];

    # Tell the QueryRunner to shutdown so it can be restarted
    if($out eq 'reload'){
        my $wheel = $h->{wheels}{$h->{QueryRunner}};
        $wheel->put(['__RELOAD__']);
        #$wheel->event(FlushedEvent => '_close');>
    }
}

# Child close event, automatically called when a child exits
sub _close {
    my ($h, $id) = @_[HEAP, ARG0];

    # Find out which type it was
    for my $c (CHILDREN){
        if( (exists $h->{$c} && ($h->{$c} == $id))){
            # Remove knowledge of the type
            delete $h->{$c};
        }
    }
    # Remove the wheel from the HEAP
    delete $h->{wheels}{$id};
}

# Passes through all output from children, STOUT and STDERR
sub _print_child_out { $_[HEAP]->{console}->put($_[ARG0]) }

# Starts a separate, i.e. forked, process to handle queries.
sub _run_query {
    my ($args) = @_; 
    
    require DDG;
    DDG->import;
    require DDG::Request;
    DDG::Request->import;
    require DDG::Test::Location;
    DDG::Test::Location->import;
    require DDG::Test::Language;
    DDG::Test::Language->import;

    my $app = App::DuckPAN->new;
    # Create our instant answers.  Should grab all of the latest files
    # in the IA directory
    my @blocks = $app->ddg->get_blocks_from_current_dir(@$args);

    select(STDOUT);$|=1;

    my $filter = POE::Filter::Reference->new;
    my ($size, $raw)  = (1024);
    # This loop reads from the main session
    READ: while(sysread(STDIN, $raw, $size)){
        # Convert raw input into perl references
        my $inputs = $filter->get([$raw]);
        # Can be more than one query at a time
        my $reload;
        for my $input (@$inputs){
            # Each put is an array ref where the first arg is the string
            my $query = shift @$input;
            # Updated files detected, let's reload. However, let's process
            # all queries first, otherwise they'll be lost
            if($query eq '__RELOAD__'){ ++$reload }
    
            my @results;
            try {
                my $request = DDG::Request->new(
                    query_raw => $query,
                    location => test_location_by_env(),
                    language => test_language_by_env(),
                );
                my $hit;
                # Iterate through the IAs, giving them our query
                for my $b (@blocks) {
                    for ($b->request($request)) {
                        $hit = 1;
                        $app->emit_info('---', p($_, colored => $app->colors), '---');
                    }
                }
                unless ($hit) {
                    $app->emit_info('Sorry, no hit on your instant answer');
                }
            }
            catch {
                my $error = $_;
                if ($error =~ /Malformed UTF-8 character/) {
                    $app->emit_info('You got a malformed utf8 error message. Normally' . 
                        ' it means that you tried to enter a special character at the query' . 
                        ' prompt but your interface is not properly configured for utf8.' . 
                        ' Please check the documentation for your terminal, ssh client' .
                        ' or other client used to execute duckpan.');
                }
                $app->emit_info("Caught error: $error");
            };
        }
        last READ if $reload;
    }
}

# Monitor the IA directory for changes
sub _fs_monitor {
    my $base_dir = shift;

    select(STDOUT);$|=1;

    while(1){
        # Find all subdirectories
        my @dirs = File::Find::Rule->directory()->in($base_dir);
        # Create our watcher with each directory
        my $watcher = Filesys::Notify::Simple->new(\@dirs);
        # Wait for something to happen.  This blocks, which is why
        # it's in a wheell.  On detection of update it will fall
        # through; thus the while(1)
        $watcher->wait(sub {
            my $reload;
            for my $event (@_) {
                # if it's just a newly created directory, there shouldn't
                # be a need to reload
                next if -d $event->{path};
                # All other changes trigger a reload
                ++$reload;
            }
            if($reload){
                # Send message to parent to reload
                print "reload\n"; 
            }
        });
    }
}
 
1;
