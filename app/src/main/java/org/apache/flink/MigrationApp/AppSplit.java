/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package org.apache.flink.MigrationApp;

	import org.apache.flink.MigrationApi.ClientServerProtocol;
	import org.apache.flink.MigrationApi.SkewnessDetector;
	import org.apache.flink.MigrationApi.UpStreamPF;
	import org.apache.flink.api.common.functions.FlatMapFunction;
	import org.apache.flink.api.java.functions.KeySelector;
	import org.apache.flink.api.java.tuple.Tuple3;
	import org.apache.flink.api.java.tuple.Tuple4;
	import org.apache.flink.configuration.Configuration;
	import org.apache.flink.streaming.api.CheckpointingMode;
	import org.apache.flink.streaming.api.windowing.time.Time;
	import org.apache.flink.api.java.tuple.Tuple2;
	import org.apache.flink.streaming.api.datastream.DataStream;
	import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
	import org.apache.flink.util.Collector;

	import java.nio.charset.StandardCharsets;

/**
 * Skeleton for a Flink Streaming Job.
 *
 * <p>For a tutorial how to write a Flink streaming application, check the
 * tutorials and examples on the <a href="http://flink.apache.org/docs/stable/">Flink Website</a>.
 *
 * <p>To package your application into a JAR file for execution, run
 * 'mvn clean package' on the command line.
 *
 * <p>If you change the name of the main class (with the public static void main(String[] args))
 * method, change the respective entry in the POM.xml file (simply search for 'mainClass').
 */
public class AppSplit {

	public static void main(String[] args) throws Exception {
		// set up the streaming execution environment
		Configuration conf=new Configuration();
		//conf.setBoolean(ConfigConstants.LOCAL_START_WEBSERVER, true);

		/*
		first one for local test;
		second one for cluster;
		 */

		//final StreamExecutionEnvironment env = StreamExecutionEnvironment.createLocalEnvironmentWithWebUI(conf);
		final StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
		//env.getConfig().setLatencyTrackingInterval(100);

		env.enableCheckpointing(5000);
		env.getCheckpointConfig().setCheckpointingMode(CheckpointingMode.EXACTLY_ONCE);
		env.getCheckpointConfig().setMaxConcurrentCheckpoints(1);
		env.setBufferTimeout(1);


		DataStream<Long> dataStream = env
			.readTextFile(args[5]).setParallelism(1).slotSharingGroup("0")
			.flatMap(new KeyGen()).setParallelism(1).startNewChain().slotSharingGroup("0")
			.flatMap(new SkewnessDetector<>(
				new KS(), Float.parseFloat(args[1]), Integer.parseInt(args[2]))).setParallelism(1).slotSharingGroup("0")
			.flatMap(new Splitter()).setParallelism(3).slotSharingGroup("0")
			.partitionCustom(new UpStreamPF<Integer>(), 1)
			.flatMap(new DownStreamSplit()).setParallelism(Integer.parseInt(args[0])).slotSharingGroup("0")
			.flatMap(new Tail(Integer.parseInt(args[0]), Integer.parseInt(args[2]))).setParallelism(1).slotSharingGroup("0");
		//dataStream.writeAsText("/home/mike/Documents/o "+ String.join("-",args)+".txt").setParallelism(1);

		StringBuilder s= new StringBuilder(args[6]);
		for (int i=0; i<args.length-2; i++) s.append(args[i]).append("-");
		s.append("bid.txt");
		System.out.println("output file: "+s);
		dataStream.writeAsText(s.toString()).setParallelism(1);


		env.execute("Flink Streaming Java API Skeleton");
	}

}
