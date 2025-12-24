using UnityEngine;
using UnityEngine.UI;
using TMPro;

public class PlayerHealthBarScript : MonoBehaviour
{
    public int stateCount;
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public Image image;
    public Sprite[] healthBarStates;
    public TMP_Text healthText;

    public void UpdateHealthBar()
    {
        float increment = 1f / (float)(stateCount - 1);
        float[] incrementArray = new float[stateCount + 1];
        for (int i = 0; i < stateCount + 1; i++)
        {
            incrementArray[i] = i * increment;
        }
        float currentHealth = (float)playerScript.CurrentHealth;
        float maxHealth = (float)playerScript.MaxHealth;
        float healthRatio = currentHealth / maxHealth;
        for (int i = 0; i < stateCount; i++)
        {
            if (incrementArray[i] <= healthRatio && healthRatio < incrementArray[i + 1])
            {
                image.sprite = healthBarStates[i];
            }
        }
        healthText.text = currentHealth.ToString();
    }

    void Start()
    {
        stateCount = 13;
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<PlayerCharacterScript>();
        image = this.gameObject.GetComponent<Image>();
        healthBarStates = new Sprite[stateCount];
        healthBarStates = Resources.LoadAll<Sprite>("PlayerHealthBar");
        healthText = this.transform.Find("Health Text").gameObject.GetComponent<TMP_Text>();
    }
}
