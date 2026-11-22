import { styled } from "@yak/react";
import { createRoot } from "react-dom/client";

const Title = styled.h1`
  color: rebeccapurple;
`;

createRoot(document.getElementById("root")!).render(<Title>hello</Title>);
