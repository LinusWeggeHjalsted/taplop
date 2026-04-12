using UnityEngine;
using UnityEngine.UI;
using TMPro;

public class PlayerHealthBarScript : MonoBehaviour
{
    public int stateCount;
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public GameObject healthBarStateSprite;
    public Image stateImage;
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
                stateImage.sprite = healthBarStates[i];
            }
        }
        healthText.text = currentHealth.ToString();
    }

    void Awake()
    {
        stateCount = 13;
        healthBarStateSprite = this.transform.Find("Health Bar State Sprite").gameObject;
        stateImage = healthBarStateSprite.GetComponent<Image>();
        healthBarStates = new Sprite[stateCount];
        healthBarStates = Resources.LoadAll<Sprite>("PlayerHealthBarStates");
        healthText = this.transform.Find("Health Text").gameObject.GetComponent<TMP_Text>();
    }

    void Start()
    {
        player = GameReferences.GetPlayer();
        if (player != null)
        {
            playerScript = player.GetComponent<PlayerCharacterScript>();
        }
    }
}
