import React, { useState, useEffect } from 'react';
import axios from 'axios';

const GATEWAY_URL = process.env.REACT_APP_API_URL
  || (window.location.hostname === "localhost"
    ? "http://localhost:8080/api/products"
    : "/api/products");

function App() {
  const [products, setProducts] = useState([]);
  const [name, setName] = useState('');
  const [price, setPrice] = useState('');
  const [stock, setStock] = useState('');

  const fetchProducts = async () => {
    try {
      const response = await axios.get(GATEWAY_URL);
      setProducts(response.data);
    } catch (error) {
      console.error("Error fetching items", error);
    }
  };

  useEffect(() => {
    fetchProducts();
  }, []);

  const handleAddProduct = async (e) => {
    e.preventDefault();
    try {
      await axios.post(GATEWAY_URL, 
        { name, price: parseFloat(price), stock: parseInt(stock) },
        { auth: { username: 'admin', password: 'admin123' } }
      );
      setName(''); setPrice(''); setStock('');
      fetchProducts();
    } catch (error) {
      alert("Unauthorized or server error. Only admin can add products!");
    }
  };

  return (
    <div style={{ padding: '20px', fontFamily: 'Arial' }}>
      <h1>🏭 Industrial Inventory Dashboard</h1>
      <form onSubmit={handleAddProduct} style={{ marginBottom: '20px' }}>
        <h3>Add New Asset (Admin Protected)</h3>
        <input placeholder="Item Name" value={name} onChange={e => setName(e.target.value)} required style={{marginRight: '5px'}}/>
        <input placeholder="Price" type="number" value={price} onChange={e => setPrice(e.target.value)} required style={{marginRight: '5px'}}/>
        <input placeholder="Stock Quantity" type="number" value={stock} onChange={e => setStock(e.target.value)} required style={{marginRight: '5px'}}/>
        <button type="submit">Save to Cloud Inventory</button>
      </form>
      <h3>Current Stock Sheets</h3>
      <table border="1" cellPadding="10" style={{ width: '100%', borderCollapse: 'collapse' }}>
        <thead>
          <tr><th>ID</th><th>Asset Name</th><th>Price</th><th>Stock Status</th></tr>
        </thead>
        <tbody>
          {products.map(p => (
            <tr key={p.id}>
              <td>{p.id}</td><td>{p.name}</td><td>${p.price.toFixed(2)}</td><td>{p.stock} units</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
export default App;
