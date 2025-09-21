using UnityEngine;

public class EntityScript : MonoBehaviour
{
    public int speed = 1;
    public int maxHealth = 10;
    public int currentHealth = 10;
    public int armor = 0;
    public Vector3 previousPosition = new Vector3();

    void Start()
    {
        Debug.Log("Hello World!");
        currentHealth = maxHealth;
        speed = 3;
    }

    void Update()
    {
        
    }
}
